defmodule HermitWeb.DNSController do
  use HermitWeb, :controller
  import Bitwise
  require Logger

  @doh_token_cache_ttl_ms 600_000

  def query(conn, %{"doh_token" => doh_token} = params) do
    case get_endpoint_by_doh_token_cached(doh_token) do
      nil ->
        conn
        |> put_status(404)
        |> text("DNS Endpoint not found")

      endpoint ->
        endpoint_id = endpoint.id

        case get_dns_packet(conn, params) do
          {:ok, query_packet} ->
            client_ip = get_client_ip(conn)
            device_name = get_device_name(conn)
            client_id = {:doh, client_ip, device_name}

            case Hermit.Dns.Server.resolve_fast_path(endpoint_id, query_packet, client_id) do
              {:ok, response_packet} ->
                conn
                |> put_resp_header("content-type", "application/dns-message")
                |> send_resp(200, response_packet)

              :miss ->
                server_target =
                  case Registry.lookup(Hermit.Vpn.Registry, {:dns_server, endpoint_id}) do
                    [{pid, _}] ->
                      {:ok, pid}

                    [] ->
                      if endpoint.enabled do
                        case Hermit.Vpn.DnsSupervisor.start_dns(
                               endpoint.id,
                               endpoint.inbound_profile_id
                             ) do
                          {:ok, {_worker, pid}} when is_pid(pid) ->
                            {:ok, pid}

                          _ ->
                            case Registry.lookup(Hermit.Vpn.Registry, {:dns_server, endpoint_id}) do
                              [{pid, _}] -> {:ok, pid}
                              [] -> :unavailable
                            end
                        end
                      else
                        :disabled
                      end
                  end

                case server_target do
                  {:ok, pid} ->
                    result =
                      try do
                        GenServer.call(
                          pid,
                          {:resolve_query, query_packet, client_id},
                          4000
                        )
                      catch
                        :exit, {:timeout, _} ->
                          Logger.error("DNS query timed out for endpoint: #{endpoint_id}")
                          {:servfail, Hermit.Dns.Packet.build_servfail(query_packet)}

                        :exit, reason ->
                          Logger.error(
                            "DNS Server call exited for endpoint #{endpoint_id}: #{inspect(reason)}"
                          )

                          {:servfail, Hermit.Dns.Packet.build_servfail(query_packet)}
                      end

                    case result do
                      {:ok, response_packet} ->
                        conn
                        |> put_resp_header("content-type", "application/dns-message")
                        |> send_resp(200, response_packet)

                      {:servfail, servfail_packet} ->
                        conn
                        |> put_resp_header("content-type", "application/dns-message")
                        |> send_resp(200, servfail_packet)

                      {:error, reason} ->
                        Logger.error("DNS Server call failed: #{inspect(reason)}")

                        conn
                        |> put_status(500)
                        |> text("Internal Server Error")
                    end

                  :disabled ->
                    conn
                    |> put_status(403)
                    |> text("DNS Endpoint is disabled")

                  :unavailable ->
                    conn
                    |> put_status(503)
                    |> text("DNS Server temporarily unavailable")
                end
            end

          {:error, :missing_dns_parameter} ->
            port_suffix = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
            server_url = "https://#{conn.host}#{port_suffix}/dns-query/#{doh_token}"
            render_mobile_config_page(conn, endpoint, server_url)

          {:error, reason} ->
            Logger.warning("Failed to get DNS packet from request: #{inspect(reason)}")

            conn
            |> put_status(400)
            |> text("Bad Request")
        end
    end
  end

  def mobileconfig(conn, %{"doh_token" => doh_token}) do
    case Hermit.Vpn.DnsEndpoint.get_by_doh_token(doh_token) do
      nil ->
        conn
        |> put_status(404)
        |> text("DNS Endpoint not found")

      endpoint ->
        port_suffix = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
        server_url = "https://#{conn.host}#{port_suffix}/dns-query/#{doh_token}"

        escaped_url = escape_xml(server_url)
        escaped_name = escape_xml(endpoint.name)
        escaped_token = escape_xml(doh_token)

        payload_uuid = generate_uuid()
        profile_uuid = generate_uuid()

        xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>PayloadContent</key>
          <array>
            <dict>
              <key>DNSSettings</key>
              <dict>
                <key>DNSProtocol</key>
                <string>HTTPS</string>
                <key>ServerURL</key>
                <string>#{escaped_url}</string>
              </dict>
              <key>PayloadDescription</key>
              <string>Configures encrypted DNS-over-HTTPS (DoH) for Hermit DNS Endpoint: #{escaped_name}</string>
              <key>PayloadDisplayName</key>
              <string>Hermit DNS - #{escaped_name}</string>
              <key>PayloadIdentifier</key>
              <string>com.hermit.dns.doh.#{escaped_token}</string>
              <key>PayloadType</key>
              <string>com.apple.dnsSettings.managed</string>
              <key>PayloadUUID</key>
              <string>#{payload_uuid}</string>
              <key>PayloadVersion</key>
              <integer>1</integer>
            </dict>
          </array>
          <key>PayloadDescription</key>
          <string>Encrypted DNS Configuration Profile generated by Hermit.</string>
          <key>PayloadDisplayName</key>
          <string>Hermit Encrypted DNS (#{escaped_name})</string>
          <key>PayloadIdentifier</key>
          <string>com.hermit.dns.profile.#{escaped_token}</string>
          <key>PayloadType</key>
          <string>Configuration</string>
          <key>PayloadUUID</key>
          <string>#{profile_uuid}</string>
          <key>PayloadVersion</key>
          <integer>1</integer>
        </dict>
        </plist>
        """

        # Slugify endpoint name for filename safety
        safe_name = String.replace(endpoint.name, ~r/[^a-zA-Z0-9_\-]/, "_")

        conn
        |> put_resp_content_type("application/x-apple-aspen-config")
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"hermit_dns_#{safe_name}.mobileconfig\""
        )
        |> send_resp(200, sign_profile(xml))
    end
  end

  defp get_endpoint_by_doh_token_cached(doh_token) do
    now = System.monotonic_time(:millisecond)

    if :ets.info(:inbound_profiles_cache) != :undefined do
      case :ets.lookup(:inbound_profiles_cache, {:doh_token, doh_token}) do
        [{_, endpoint, expires_at}] when expires_at > now ->
          endpoint

        _ ->
          endpoint = Hermit.Vpn.DnsEndpoint.get_by_doh_token(doh_token)

          if endpoint && endpoint.enabled do
            :ets.insert(
              :inbound_profiles_cache,
              {{:doh_token, doh_token}, endpoint, now + @doh_token_cache_ttl_ms}
            )
          end

          endpoint
      end
    else
      Hermit.Vpn.DnsEndpoint.get_by_doh_token(doh_token)
    end
  rescue
    _ -> Hermit.Vpn.DnsEndpoint.get_by_doh_token(doh_token)
  end

  defp sign_profile(xml) do
    base_path = Application.get_env(:hermit, :storage)[:base_path] || File.cwd!()

    phx_host =
      System.get_env("PHX_HOST") || Application.get_env(:hermit, HermitWeb.Endpoint)[:url][:host] ||
        "localhost"

    cert_dir = Path.join([base_path, "certs", phx_host])

    key_path = Path.join(cert_dir, "privkey.pem")
    cert_path = Path.join(cert_dir, "cert.pem")

    generate_self_signed_cert(cert_dir, phx_host)

    if File.exists?(key_path) and File.exists?(cert_path) do
      temp_xml_path = Path.join(System.tmp_dir!(), "temp_profile_#{generate_uuid()}.xml")

      try do
        File.write!(temp_xml_path, xml)

        chain_path = Path.join(cert_dir, "chain.pem")

        openssl_args =
          if File.exists?(chain_path) do
            [
              "smime",
              "-sign",
              "-signer",
              cert_path,
              "-inkey",
              key_path,
              "-certfile",
              chain_path,
              "-nodetach",
              "-outform",
              "der",
              "-in",
              temp_xml_path
            ]
          else
            [
              "smime",
              "-sign",
              "-signer",
              cert_path,
              "-inkey",
              key_path,
              "-nodetach",
              "-outform",
              "der",
              "-in",
              temp_xml_path
            ]
          end

        case System.cmd("openssl", openssl_args) do
          {signed_der, 0} ->
            signed_der

          {error_log, status} ->
            Logger.warning(
              "OpenSSL configuration profile signing failed with status #{status}: #{error_log}. Serving unsigned xml instead."
            )

            xml
        end
      after
        File.rm(temp_xml_path)
      end
    else
      xml
    end
  end

  defp generate_self_signed_cert(cert_dir, phx_host) do
    key_path = Path.join(cert_dir, "privkey.pem")
    cert_path = Path.join(cert_dir, "cert.pem")

    if not File.exists?(key_path) or not File.exists?(cert_path) do
      File.mkdir_p!(cert_dir)

      Logger.info(
        "Self-signed configuration profile signing certs not found. Creating dynamic certs..."
      )

      safe_cn = String.replace(phx_host, ~r/[\r\n]/, "")

      custom_cnf = """
      [req]
      distinguished_name = req_distinguished_name
      prompt = no

      [req_distinguished_name]
      CN = #{safe_cn}
      O = Hermit DNS
      OU = Secure Provisioning
      C = US
      """

      cnf_path = Path.join(cert_dir, "openssl.cnf")

      try do
        File.write!(cnf_path, custom_cnf)

        case System.cmd("openssl", [
               "req",
               "-new",
               "-newkey",
               "rsa:2048",
               "-days",
               "3650",
               "-nodes",
               "-x509",
               "-config",
               cnf_path,
               "-keyout",
               key_path,
               "-out",
               cert_path
             ]) do
          {_output, 0} ->
            _ = File.chmod(key_path, 0o600)
            Logger.info("Signing certificates generated successfully at #{cert_dir}")

          {err, status} ->
            Logger.error("Failed to generate profile signing certs (code #{status}): #{err}")
        end
      after
        File.rm(cnf_path)
      end
    end
  end

  defp get_dns_packet(_conn, %{"dns" => dns_b64} = _params) do
    # GET method uses base64url query param
    case Base.url_decode64(dns_b64, padding: false) do
      {:ok, binary} -> {:ok, binary}
      _ -> {:error, :bad_base64}
    end
  end

  defp get_dns_packet(conn, _params) do
    # POST method body contains raw binary dns message
    content_type = get_header(conn, "content-type")

    if content_type == "application/dns-message" do
      case Plug.Conn.read_body(conn) do
        {:ok, body, _conn} -> {:ok, body}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing_dns_parameter}
    end
  end

  defp render_mobile_config_page(conn, endpoint, server_url) do
    escaped_name = escape_html(endpoint.name)
    escaped_url = escape_html(server_url)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, """
    <!DOCTYPE html>
    <html lang="en" data-theme="dark">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Hermit DNS Endpoint: #{escaped_name}</title>
      <style>
        *{box-sizing:border-box;margin:0;padding:0}
        body{background:#020617;color:#f1f5f9;font-family:system-ui,-apple-system,sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:1rem}
        .card{max-width:28rem;width:100%;background:#0f172a;border:1px solid #1e293b;border-radius:1rem;padding:1.5rem;box-shadow:0 20px 25px -5px rgba(0,0,0,.4)}
        .center{text-align:center;margin-bottom:1.5rem}
        .icon{font-size:2.25rem;display:block;margin-bottom:.5rem}
        h2{font-size:1.25rem;font-weight:700;color:#34d399;margin-bottom:.25rem}
        .sub{font-size:.75rem;color:#94a3b8;font-family:ui-monospace,monospace}
        .box{background:rgba(2,6,23,.6);border:1px solid rgba(30,41,59,.8);border-radius:.75rem;padding:1rem;margin-bottom:1.5rem}
        h3{font-size:.75rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:#94a3b8;margin-bottom:.75rem}
        code{display:block;background:#020617;padding:.5rem .75rem;border-radius:.375rem;font-size:.75rem;color:#34d399;word-break:break-all;font-family:ui-monospace,monospace;user-select:all}
        .desc{font-size:.75rem;color:#94a3b8;line-height:1.5;margin-bottom:.75rem}
        .btn{display:block;width:100%;text-align:center;background:#059669;color:#fff;padding:.625rem 1rem;border-radius:.5rem;font-size:.875rem;font-weight:600;text-decoration:none}
        .btn:hover{background:#10b981}
        .footer{border-top:1px solid #1e293b;padding-top:1rem;margin-top:1.5rem;text-align:center;font-size:.625rem;color:#64748b}
      </style>
    </head>
    <body>
      <div class="card">
        <div class="center">
          <span class="icon">🔒</span>
          <h2>Hermit DNS Endpoint</h2>
          <p class="sub">#{escaped_name}</p>
        </div>

        <div class="box">
          <h3>Secure DoH Address</h3>
          <code>#{escaped_url}</code>
        </div>

        <div>
          <h3>iOS / macOS Auto Setup</h3>
          <p class="desc">
            Download the Apple Provisioning profile below. Once downloaded, open your Settings app and install the profile to apply system-wide secure DNS filtering.
          </p>
          <a href="#{escaped_url}/mobileconfig" class="btn">
            ⬇️ Download Profile (.mobileconfig)
          </a>
        </div>

        <div class="footer">
          Hermit Encrypted DNS System
        </div>
      </div>
    </body>
    </html>
    """)
  end

  defp escape_html(val) do
    val
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp escape_xml(val) do
    val
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp generate_uuid() do
    # Generates a standard UUID version 4
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    List.to_string(
      :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    )
  end

  defp get_client_ip(conn) do
    with nil <- get_header(conn, "cf-connecting-ip") |> parse_ip(),
         nil <- get_header(conn, "true-client-ip") |> parse_ip(),
         nil <- get_header(conn, "x-real-ip") |> parse_ip(),
         nil <- get_header(conn, "x-forwarded-for") |> parse_xff_header(),
         do: conn.remote_ip
  end

  defp get_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp parse_xff_header(nil), do: nil

  defp parse_xff_header(val) do
    # Format: client, proxy1, proxy2
    val
    |> String.split(",")
    |> List.first()
    |> String.trim()
    |> parse_ip()
  end

  defp parse_ip(ip_str) when is_binary(ip_str) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp parse_ip(_), do: nil

  defp get_device_name(conn) do
    with nil <- get_header(conn, "x-device-name"),
         nil <- get_header(conn, "x-device-model") do
      ua = get_header(conn, "user-agent") || ""

      cond do
        String.contains?(ua, "iPhone") -> "iPhone"
        String.contains?(ua, "iPad") -> "iPad"
        String.contains?(ua, "Macintosh") -> "Mac"
        String.contains?(ua, "Windows") -> "Windows PC"
        String.contains?(ua, "Android") -> "Android"
        String.contains?(ua, "Linux") -> "Linux"
        true -> "Generic Device"
      end
    end
  end
end
