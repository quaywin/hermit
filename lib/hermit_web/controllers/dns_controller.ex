defmodule HermitWeb.DNSController do
  use HermitWeb, :controller
  require Logger

  def query(conn, %{"doh_token" => doh_token} = params) do
    case Hermit.Vpn.InboundProfile.get_by_doh_token(doh_token) do
      nil ->
        conn
        |> put_status(404)
        |> text("Profile not found")

      profile ->
        profile_id = profile.id

        case get_dns_packet(conn, params) do
          {:ok, query_packet} ->
            case Registry.lookup(Hermit.Vpn.Registry, {:dns_server, profile_id}) do
              [{pid, _}] ->
                client_ip = get_client_ip(conn)
                device_name = get_device_name(conn)

                case GenServer.call(
                       pid,
                       {:resolve_query, query_packet, {:doh, client_ip, device_name}},
                       5000
                     ) do
                  {:ok, response_packet} ->
                    conn
                    |> put_resp_header("content-type", "application/dns-message")
                    |> send_resp(200, response_packet)

                  {:error, reason} ->
                    Logger.error("DNS Server call failed: #{inspect(reason)}")

                    conn
                    |> put_status(500)
                    |> text("Internal Server Error")
                end

              [] ->
                conn
                |> put_status(404)
                |> text("DNS Server not running for profile")
            end

          {:error, :missing_dns_parameter} ->
            # Render a friendly helper page for GET requests without dns parameter (browser visits)
            config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)
            port_suffix = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
            server_url = "https://#{conn.host}#{port_suffix}/dns-query/#{doh_token}"
            render_mobile_config_page(conn, config, server_url)

          {:error, reason} ->
            Logger.warning("Failed to get DNS packet from request: #{inspect(reason)}")

            conn
            |> put_status(400)
            |> text("Bad Request")
        end
    end
  end

  def mobileconfig(conn, %{"doh_token" => doh_token}) do
    case Hermit.Vpn.InboundProfile.get_by_doh_token(doh_token) do
      nil ->
        conn |> put_status(404) |> text("Not Found")

      profile ->
        profile_id = profile.id
        config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)
        port_suffix = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
        server_url = "https://#{conn.host}#{port_suffix}/dns-query/#{doh_token}"

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
                        <string>#{server_url}</string>
                    </dict>
                    <key>PayloadDescription</key>
                    <string>Configure DNS over HTTPS for Hermit Profile #{config.name}</string>
                    <key>PayloadDisplayName</key>
                    <string>Hermit DoH - #{config.name}</string>
                    <key>PayloadIdentifier</key>
                    <string>com.hermit.dns.#{profile_id}</string>
                    <key>PayloadType</key>
                    <string>com.apple.dnsSettings.managed</string>
                    <key>PayloadUUID</key>
                    <string>#{payload_uuid}</string>
                    <key>PayloadVersion</key>
                    <integer>1</integer>
                </dict>
            </array>
            <key>PayloadDisplayName</key>
            <string>Hermit DNS - #{config.name}</string>
            <key>PayloadIdentifier</key>
            <string>com.hermit.profile.dns.#{profile_id}</string>
            <key>PayloadType</key>
            <string>Configuration</string>
            <key>PayloadUUID</key>
            <string>#{profile_uuid}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
        </plist>
        """

        response_data =
          case sign_profile(xml) do
            {:ok, signed} -> signed
            {:error, _} -> xml
          end

        conn
        |> put_resp_header("content-type", "application/x-apple-aspen-config")
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"hermit-dns-#{profile_id}.mobileconfig\""
        )
        |> send_resp(200, response_data)
    end
  end

  defp sign_profile(xml) do
    phx_host = System.get_env("PHX_HOST")

    if phx_host && phx_host not in [nil, "", "localhost", "127.0.0.1"] do
      storage_dir = Application.get_env(:hermit, :storage)[:base_path] || "/app/storage"

      # Check both the root certs/ directory and the site_encrypt domain-specific directory
      certs_dirs = [
        Path.join([storage_dir, "certs", phx_host]),
        Path.join(storage_dir, "certs")
      ]

      cert_path = find_existing_file_in_dirs(certs_dirs, ["cert.pem", "fullchain.pem"])
      key_path = find_existing_file_in_dirs(certs_dirs, ["privkey.pem", "key.pem"])

      {cert_path, key_path} =
        if cert_path && key_path do
          {cert_path, key_path}
        else
          # Fallback to generating self-signed in the domain directory
          generate_self_signed_cert(Path.join([storage_dir, "certs", phx_host]), phx_host)
        end

      chain_path = find_existing_file_in_dirs(certs_dirs, ["chain.pem"])

      if cert_path && key_path do
        random_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
        temp_xml_path = Path.join(System.tmp_dir!(), "temp_profile_#{random_suffix}.xml")

        try do
          File.write!(temp_xml_path, xml)

          args = [
            "smime",
            "-sign",
            "-signer",
            cert_path,
            "-inkey",
            key_path,
            "-outform",
            "der",
            "-nodetach",
            "-in",
            temp_xml_path
          ]

          args = if chain_path, do: args ++ ["-certfile", chain_path], else: args

          case System.cmd("openssl", args) do
            {signed_binary, 0} ->
              {:ok, signed_binary}

            {error_msg, status} ->
              Logger.error(
                "DNS Server: OpenSSL profile signing failed (status #{status}): #{inspect(error_msg)}"
              )

              {:error, :signing_failed}
          end
        rescue
          exception ->
            Logger.error(
              "DNS Server: OpenSSL execution failed during signing: #{inspect(exception)}"
            )

            {:error, :signing_failed}
        after
          File.rm(temp_xml_path)
        end
      else
        {:error, :missing_certs}
      end
    else
      {:error, :no_signing_host}
    end
  end

  defp generate_self_signed_cert(certs_dir, phx_host) do
    File.mkdir_p!(certs_dir)
    cert_path = Path.join(certs_dir, "cert.pem")
    key_path = Path.join(certs_dir, "privkey.pem")

    cmd_args = [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-keyout",
      key_path,
      "-out",
      cert_path,
      "-days",
      "3650",
      "-nodes",
      "-subj",
      "/CN=#{phx_host}"
    ]

    try do
      case System.cmd("openssl", cmd_args) do
        {_, 0} ->
          Logger.info(
            "DNS Server: Generated self-signed certificates for #{phx_host} at #{certs_dir}"
          )

          {cert_path, key_path}

        {error, status} ->
          Logger.error(
            "DNS Server: Failed to generate self-signed certificates (status #{status}): #{inspect(error)}"
          )

          {nil, nil}
      end
    rescue
      exception ->
        Logger.error(
          "DNS Server: Failed to execute openssl command for self-signed certificate generation: #{inspect(exception)}"
        )

        {nil, nil}
    end
  end

  defp find_existing_file_in_dirs(dirs, filenames) do
    Enum.find_value(dirs, fn dir ->
      Enum.find_value(filenames, fn filename ->
        path = Path.join(dir, filename)
        if File.exists?(path), do: path
      end)
    end)
  end

  defp get_dns_packet(conn, params) do
    cond do
      conn.method == "POST" ->
        case read_body(conn) do
          {:ok, body, _conn} -> {:ok, body}
          {:more, _body, _conn} -> {:error, :body_too_large}
        end

      conn.method == "GET" ->
        dns_param = Map.get(params, "dns")

        if dns_param do
          # Try decoding base64url without padding first, then with padding
          case Base.url_decode64(dns_param, padding: false) do
            {:ok, packet} ->
              {:ok, packet}

            _ ->
              case Base.url_decode64(dns_param) do
                {:ok, packet} -> {:ok, packet}
                _ -> {:error, :invalid_base64url}
              end
          end
        else
          {:error, :missing_dns_parameter}
        end

      true ->
        {:error, :unsupported_method}
    end
  end

  defp render_mobile_config_page(conn, config, server_url) do
    port_suffix = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
    logo_url = "https://#{conn.host}#{port_suffix}/images/logo.png"

    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Hermit DNS - #{config.name}</title>
      <style>
        body {
          font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          background-color: #fafafa;
          color: #171717;
          margin: 0;
          padding: 24px;
          display: flex;
          justify-content: center;
          align-items: center;
          min-height: 80vh;
        }
        .card {
          background-color: #ffffff;
          border: 1px solid #dfdfdf;
          border-radius: 12px;
          padding: 32px 24px;
          max-width: 480px;
          width: 100%;
          box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05), 0 2px 4px -2px rgba(0, 0, 0, 0.05);
        }
        .logo-container {
          display: flex;
          align-items: center;
          gap: 12px;
          margin-bottom: 24px;
          border-bottom: 1px solid #dfdfdf;
          padding-bottom: 16px;
        }
        .logo-text {
          font-weight: 700;
          font-size: 18px;
          text-transform: uppercase;
          letter-spacing: 0.1em;
          color: #171717;
        }
        h1 {
          font-size: 16px;
          font-weight: 600;
          margin-top: 0;
          margin-bottom: 8px;
          color: #171717;
          text-transform: uppercase;
          letter-spacing: 0.05em;
        }
        p {
          font-size: 13px;
          color: #64748b;
          line-height: 1.5;
          margin-top: 0;
          margin-bottom: 16px;
        }
        strong {
          color: #171717;
        }
        .url-box {
          background-color: #fafafa;
          border: 1px solid #dfdfdf;
          border-radius: 6px;
          padding: 12px;
          font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
          font-size: 12px;
          word-break: break-all;
          margin: 12px 0 20px 0;
          color: #10b981;
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 12px;
        }
        .btn {
          display: block;
          width: 100%;
          background-color: #3ecf8e;
          color: #171717;
          text-align: center;
          padding: 12px 0;
          border-radius: 6px;
          font-weight: 600;
          font-size: 13px;
          text-decoration: none;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          margin-top: 16px;
          transition: background-color 0.2s, border-color 0.2s;
          box-sizing: border-box;
          border: 1px solid #3ecf8e;
        }
        .btn:hover {
          background-color: #24b47e;
          border-color: #24b47e;
        }
        .btn-copy {
          background: none;
          border: none;
          color: #3ecf8e;
          cursor: pointer;
          font-size: 11px;
          text-transform: uppercase;
          font-weight: 600;
          flex-shrink: 0;
          padding: 0;
          transition: color 0.2s;
        }
        .btn-copy:hover {
          color: #24b47e;
        }
        .section-title {
          font-size: 11px;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: #94a3b8;
          margin-top: 24px;
          margin-bottom: 8px;
          font-weight: bold;
        }
        ul {
          padding-left: 20px;
          margin: 0;
          font-size: 13px;
          color: #64748b;
          line-height: 1.6;
        }
        li {
          margin-bottom: 6px;
        }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="logo-container">
          <img src="#{logo_url}" width="30" height="30" alt="Hermit Logo" />
          <span class="logo-text">Hermit</span>
        </div>

        <h1>Hermit DNS Profile</h1>
        <p>Profile: <strong>#{config.name}</strong></p>

        <div class="section-title">DNS-over-HTTPS (DoH) URL</div>
        <div class="url-box">
          <span id="doh-url">#{server_url}</span>
          <button class="btn-copy" onclick="copyUrl()">Copy</button>
        </div>

        <div class="section-title">Apple Devices (iOS / macOS)</div>
        <p>Install this configuration profile to automatically configure secure DoH settings on your iPhone, iPad, or Mac.</p>
        <a href="#{server_url}/mobileconfig" class="btn">Download Config Profile</a>

        <div class="section-title">Android Settings</div>
        <ul>
          <li>Android 13+ supports DoH via custom apps or secure browser settings.</li>
          <li>For system-wide secure DNS, copy the DoH URL above and paste it into your preferred secure DNS app (e.g. Nebulo or Intra).</li>
        </ul>
      </div>

      <script>
        function copyUrl() {
          const urlText = document.getElementById('doh-url').innerText;
          navigator.clipboard.writeText(urlText).then(() => {
            const btn = document.querySelector('.btn-copy');
            btn.innerText = 'Copied!';
            setTimeout(() => {
              btn.innerText = 'Copy';
            }, 2000);
          });
        }
      </script>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp generate_uuid() do
    raw = :crypto.strong_rand_bytes(16)
    <<u0::48, _v::4, u1::12, _r::2, u2::62>> = raw
    bin = <<u0::48, 4::4, u1::12, 2::2, u2::62>>

    <<a::32, b::16, c::16, d::16, e::48>> = bin

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c, d, e]
    )
    |> List.to_string()
  end

  defp get_client_ip(conn) do
    cond do
      cf_ip = get_header(conn, "cf-connecting-ip") ->
        cf_ip

      forwarded_for = get_header(conn, "x-forwarded-for") ->
        forwarded_for
        |> String.split(",")
        |> List.first()
        |> String.trim()

      real_ip = get_header(conn, "x-real-ip") ->
        real_ip
        |> String.trim()

      true ->
        nil
    end
    |> case do
      nil ->
        conn.remote_ip

      ip_str ->
        case parse_ip(ip_str) do
          {:ok, ip} -> ip
          _ -> conn.remote_ip
        end
    end
  end

  defp get_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp parse_ip(ip_str) do
    ip_str
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp get_device_name(conn) do
    cond do
      dev = get_header(conn, "x-device-name") -> dev
      dev = get_header(conn, "x-client-device") -> dev
      dev = get_header(conn, "x-dns-device") -> dev
      dev = get_header(conn, "x-forwarded-device") -> dev
      dev = get_header(conn, "x-dns-client-id") -> dev
      dev = get_header(conn, "x-client-id") -> dev
      true -> nil
    end
    |> case do
      nil -> nil
      str -> String.trim(str)
    end
  end
end
