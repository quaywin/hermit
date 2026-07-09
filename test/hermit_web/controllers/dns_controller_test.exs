defmodule HermitWeb.DNSControllerTest do
  use HermitWeb.ConnCase, async: false

  alias Hermit.Dns.Packet
  alias Hermit.Dns.Server

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

  test "GET/POST /dns-query/:profile_id returns correct DNS response", %{conn: conn} do
    # Create inbound profile
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "DoH_Test_Profile",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_doh_test"}
      })

    profile_id = profile.id
    # Create DNS Config
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)
    {:ok, _config} =
      Hermit.Vpn.DnsConfig.update_for_profile(profile_id, %{
        enabled: true,
        upstream_dns: "127.0.0.1",
        custom_rules: [%{"domain" => "blocked.com", "action" => "block"}]
      })

    # Start DNS server
    port = 36363 + profile_id
    {:ok, _server_pid} = Server.start_link(profile_id: profile_id, port: port)

    # 1. Populate cache manually for a domain
    domain = "dohcache.com"
    qname = <<8>> <> "dohcache" <> <<3>> <> "com" <> <<0>>
    query_packet = <<0, 15, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0>> <> qname <> <<0, 1, 0, 1>>
    query_rec = {:dns_query, domain, 1, 1}

    # Store in cache
    mock_response = Packet.build_a_response(<<0, 15>>, query_rec, "9.9.9.9")
    expires_at = System.monotonic_time(:second) + 100
    :ets.insert(:dns_cache, {{profile_id, domain, :A}, mock_response, "resolved", "9.9.9.9", expires_at})

    # Test POST method
    conn_post =
      conn
      |> put_req_header("content-type", "application/dns-message")
      |> post(~p"/dns-query/#{profile_id}", query_packet)

    assert get_resp_header(conn_post, "content-type") == ["application/dns-message"]
    assert conn_post.status == 200
    resp_body = response(conn_post, 200)
    assert byte_size(resp_body) > 12
    assert <<0, 15, _rest::binary>> = resp_body

    # Test GET method with base64url parameter
    b64_query = Base.url_encode64(query_packet, padding: false)
    conn_get = get(conn, ~p"/dns-query/#{profile_id}", %{"dns" => b64_query})

    assert get_resp_header(conn_get, "content-type") == ["application/dns-message"]
    assert conn_get.status == 200
    resp_body_get = response(conn_get, 200)
    assert <<0, 15, _rest::binary>> = resp_body_get

    # Test blocked domain (NXDOMAIN block response)
    blocked_qname = <<7>> <> "blocked" <> <<3>> <> "com" <> <<0>>
    blocked_query_packet = <<0, 16, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0>> <> blocked_qname <> <<0, 1, 0, 1>>
    
    conn_blocked =
      conn
      |> put_req_header("content-type", "application/dns-message")
      |> post(~p"/dns-query/#{profile_id}", blocked_query_packet)

    assert conn_blocked.status == 200
    blocked_resp = response(conn_blocked, 200)
    assert <<0, 16, 0x81, 0x83, _rest::binary>> = blocked_resp
  end

  test "GET /dns-query/:profile_id without dns parameter returns helper HTML page", %{conn: conn} do
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "DoH_HTML_Profile",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_doh_html"}
      })

    profile_id = profile.id
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)

    conn_html = get(conn, ~p"/dns-query/#{profile_id}")
    assert conn_html.status == 200
    assert get_resp_header(conn_html, "content-type") == ["text/html; charset=utf-8"]
    html_body = response(conn_html, 200)
    assert html_body =~ "Hermit DNS Profile"
    assert html_body =~ "iOS / macOS"
    assert html_body =~ "/dns-query/#{profile_id}/mobileconfig"
  end

  test "GET /dns-query/:profile_id/mobileconfig returns XML profile with correct content type", %{conn: conn} do
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "DoH_XML_Profile",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_doh_xml"}
      })

    profile_id = profile.id
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)

    conn_xml = get(conn, ~p"/dns-query/#{profile_id}/mobileconfig")
    assert conn_xml.status == 200
    assert get_resp_header(conn_xml, "content-type") == ["application/x-apple-aspen-config"]
    assert get_resp_header(conn_xml, "content-disposition") == ["attachment; filename=\"hermit-dns-#{profile_id}.mobileconfig\""]
    xml_body = response(conn_xml, 200)
    assert xml_body =~ "<plist version=\"1.0\">"
    assert xml_body =~ "<string>HTTPS</string>"
    assert xml_body =~ "<string>com.apple.dnsSettings.managed</string>"
  end
end
