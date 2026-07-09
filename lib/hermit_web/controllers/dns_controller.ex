defmodule HermitWeb.DNSController do
  use HermitWeb, :controller
  require Logger

  def query(conn, %{"profile_id" => profile_id_str} = params) do
    case Integer.parse(profile_id_str) do
      {profile_id, ""} ->
        case get_dns_packet(conn, params) do
          {:ok, query_packet} ->
            case Registry.lookup(Hermit.Vpn.Registry, {:dns_server, profile_id}) do
              [{pid, _}] ->
                case GenServer.call(pid, {:resolve_query, query_packet, conn.remote_ip}, 5000) do
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
            case Hermit.Repo.get(Hermit.Vpn.InboundProfile, profile_id) do
              nil ->
                conn |> put_status(404) |> text("Not Found")

              _profile ->
                config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)
                port_suffix = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
                server_url = "https://#{conn.host}#{port_suffix}/dns-query/#{profile_id}"
                render_mobile_config_page(conn, config, server_url)
            end

          {:error, reason} ->
            Logger.warning("Failed to get DNS packet from request: #{inspect(reason)}")
            conn
            |> put_status(400)
            |> text("Bad Request")
        end

      _ ->
        conn
        |> put_status(400)
        |> text("Invalid profile ID")
    end
  end

  def mobileconfig(conn, %{"profile_id" => profile_id_str}) do
    case Integer.parse(profile_id_str) do
      {profile_id, ""} ->
        case Hermit.Repo.get(Hermit.Vpn.InboundProfile, profile_id) do
          nil ->
            conn |> put_status(404) |> text("Not Found")

          _profile ->
            config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)
            port_suffix = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
            server_url = "https://#{conn.host}#{port_suffix}/dns-query/#{profile_id}"

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

            conn
            |> put_resp_header("content-type", "application/x-apple-aspen-config")
            |> put_resp_header("content-disposition", "attachment; filename=\"hermit-dns-#{profile_id}.mobileconfig\"")
            |> send_resp(200, xml)
        end

      _ ->
        conn |> put_status(400) |> text("Invalid profile ID")
    end
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
            {:ok, packet} -> {:ok, packet}
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
    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Hermit DNS - #{config.name}</title>
      <style>
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          background-color: #0f172a;
          color: #f8fafc;
          margin: 0;
          padding: 24px;
          display: flex;
          justify-content: center;
          align-items: center;
          min-height: 80vh;
        }
        .card {
          background-color: #1e293b;
          border: 1px solid #334155;
          border-radius: 12px;
          padding: 24px;
          max-width: 480px;
          width: 100%;
          box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -2px rgba(0, 0, 0, 0.1);
        }
        h1 {
          font-size: 20px;
          margin-top: 0;
          color: #38bdf8;
          text-transform: uppercase;
          letter-spacing: 0.05em;
        }
        p {
          font-size: 14px;
          color: #94a3b8;
          line-height: 1.5;
        }
        .url-box {
          background-color: #0f172a;
          border: 1px solid #334155;
          border-radius: 6px;
          padding: 12px;
          font-family: monospace;
          font-size: 12px;
          word-break: break-all;
          margin: 16px 0;
          color: #10b981;
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 12px;
        }
        .btn {
          display: block;
          width: 100%;
          background-color: #0284c7;
          color: #ffffff;
          text-align: center;
          padding: 12px 0;
          border-radius: 6px;
          font-weight: 600;
          text-decoration: none;
          margin-top: 16px;
          transition: background-color 0.2s;
          box-sizing: border-box;
        }
        .btn:hover {
          background-color: #0369a1;
        }
        .btn-copy {
          background: none;
          border: none;
          color: #38bdf8;
          cursor: pointer;
          font-size: 11px;
          text-transform: uppercase;
          font-weight: 600;
          flex-shrink: 0;
          padding: 0;
        }
        .section-title {
          font-size: 12px;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: #64748b;
          margin-top: 24px;
          margin-bottom: 8px;
          font-weight: bold;
        }
        ul {
          padding-left: 20px;
          margin: 0;
          font-size: 13px;
          color: #94a3b8;
          line-height: 1.6;
        }
      </style>
    </head>
    <body>
      <div class="card">
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
        <p style="font-size: 11px; color: #64748b; margin-top: 8px;">⚠️ Note: Apple devices will show an "Unsigned Profile" warning during installation because this profile is generated locally by your Hermit instance. This is expected and safe to install.</p>

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
end
