defmodule HermitWeb.DNSControllerTest do
  use HermitWeb.ConnCase, async: false

  alias Hermit.Dns.Packet
  alias Hermit.Dns.Server

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

  test "GET/POST /dns-query/:doh_token returns correct DNS response", %{conn: conn} do
    # Create inbound profile
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "DoH_Test_Profile",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_doh_test"},
        doh_token: "doh_test_token"
      })

    profile_id = profile.id
    doh_token = profile.doh_token
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
      |> post(~p"/dns-query/#{doh_token}", query_packet)

    assert get_resp_header(conn_post, "content-type") == ["application/dns-message"]
    assert conn_post.status == 200
    resp_body = response(conn_post, 200)
    assert byte_size(resp_body) > 12
    assert <<0, 15, _rest::binary>> = resp_body

    # Test GET method with base64url parameter
    b64_query = Base.url_encode64(query_packet, padding: false)
    conn_get = get(conn, ~p"/dns-query/#{doh_token}", %{"dns" => b64_query})

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
      |> post(~p"/dns-query/#{doh_token}", blocked_query_packet)

    assert conn_blocked.status == 200
    blocked_resp = response(conn_blocked, 200)
    assert <<0, 16, 0x81, 0x83, _rest::binary>> = blocked_resp
  end

  test "GET /dns-query/:doh_token without dns parameter returns helper HTML page", %{conn: conn} do
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "DoH_HTML_Profile",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_doh_html"},
        doh_token: "doh_html_token"
      })

    profile_id = profile.id
    doh_token = profile.doh_token
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)

    conn_html = get(conn, ~p"/dns-query/#{doh_token}")
    assert conn_html.status == 200
    assert get_resp_header(conn_html, "content-type") == ["text/html; charset=utf-8"]
    html_body = response(conn_html, 200)
    assert html_body =~ "Hermit DNS Profile"
    assert html_body =~ "iOS / macOS"
    assert html_body =~ "/dns-query/#{doh_token}/mobileconfig"
  end

  test "GET /dns-query/:doh_token/mobileconfig returns XML profile with correct content type", %{conn: conn} do
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "DoH_XML_Profile",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_doh_xml"},
        doh_token: "doh_xml_token"
      })

    profile_id = profile.id
    doh_token = profile.doh_token
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)

    conn_xml = get(conn, ~p"/dns-query/#{doh_token}/mobileconfig")
    assert conn_xml.status == 200
    assert get_resp_header(conn_xml, "content-type") == ["application/x-apple-aspen-config"]
    assert get_resp_header(conn_xml, "content-disposition") == ["attachment; filename=\"hermit-dns-#{profile_id}.mobileconfig\""]
    xml_body = response(conn_xml, 200)
    assert xml_body =~ "<plist version=\"1.0\">"
    assert xml_body =~ "<string>HTTPS</string>"
    assert xml_body =~ "<string>com.apple.dnsSettings.managed</string>"
  end

  test "GET/POST /dns-query/:doh_token extracts correct client IP from proxy headers", %{conn: conn} do
    # Create inbound profile
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "DoH_IP_Test_Profile",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_doh_ip_test"},
        doh_token: "doh_ip_test_token"
      })

    profile_id = profile.id
    doh_token = profile.doh_token
    # Create DNS Config
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)
    {:ok, _config} =
      Hermit.Vpn.DnsConfig.update_for_profile(profile_id, %{
        enabled: true,
        upstream_dns: "127.0.0.1",
        custom_rules: []
      })

    # Start DNS server
    port = 36463 + profile_id
    {:ok, _server_pid} = Server.start_link(profile_id: profile_id, port: port)

    domain = "dohip.com"
    qname = <<5>> <> "dohip" <> <<3>> <> "com" <> <<0>>
    query_packet = <<0, 17, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0>> <> qname <> <<0, 1, 0, 1>>
    query_rec = {:dns_query, domain, 1, 1}

    # Store in cache
    mock_response = Packet.build_a_response(<<0, 17>>, query_rec, "9.9.9.9")
    expires_at = System.monotonic_time(:second) + 100
    :ets.insert(:dns_cache, {{profile_id, domain, :A}, mock_response, "resolved", "9.9.9.9", expires_at})

    # Attach telemetry handler to capture client IP
    test_pid = self()
    handler_id = "test-doh-ip-handler-#{profile_id}"
    :ok = :telemetry.attach(
      handler_id,
      [:hermit, :dns, :query],
      fn _name, _measurements, metadata, _config ->
        send(test_pid, {:captured_query_metadata, metadata})
      end,
      nil
    )

    try do
      # 1. Test X-Forwarded-For (with multiple IPs)
      _conn1 =
        conn
        |> put_req_header("content-type", "application/dns-message")
        |> put_req_header("x-forwarded-for", "192.168.1.100, 10.0.0.1")
        |> post(~p"/dns-query/#{doh_token}", query_packet)

      assert_receive {:captured_query_metadata, %{client_ip: {:doh, {192, 168, 1, 100}, nil}}}

      # 2. Test X-Real-IP
      _conn2 =
        conn
        |> put_req_header("content-type", "application/dns-message")
        |> put_req_header("x-real-ip", "10.0.0.5")
        |> post(~p"/dns-query/#{doh_token}", query_packet)

      assert_receive {:captured_query_metadata, %{client_ip: {:doh, {10, 0, 0, 5}, nil}}}

      # 3. Test CF-Connecting-IP
      _conn3 =
        conn
        |> put_req_header("content-type", "application/dns-message")
        |> put_req_header("cf-connecting-ip", "2001:db8::1")
        |> post(~p"/dns-query/#{doh_token}", query_packet)

      assert_receive {:captured_query_metadata, %{client_ip: {:doh, {8193, 3512, 0, 0, 0, 0, 0, 1}, nil}}}

      # 4. Test Device Name Header (e.g. x-device-name)
      _conn4 =
        conn
        |> put_req_header("content-type", "application/dns-message")
        |> put_req_header("x-device-name", "My-Test-Device")
        |> post(~p"/dns-query/#{doh_token}", query_packet)

      assert_receive {:captured_query_metadata, %{client_ip: {:doh, _ip, "My-Test-Device"}}}
    after
      :telemetry.detach(handler_id)
    end
  end
end
