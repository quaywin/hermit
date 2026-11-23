defmodule HermitWeb.EndpointTest do
  use ExUnit.Case, async: false
  alias HermitWeb.Endpoint

  setup do
    old_check_origin = System.get_env("CHECK_ORIGIN")
    old_phx_host = System.get_env("PHX_HOST")

    on_exit(fn ->
      if old_check_origin,
        do: System.put_env("CHECK_ORIGIN", old_check_origin),
        else: System.delete_env("CHECK_ORIGIN")

      if old_phx_host,
        do: System.put_env("PHX_HOST", old_phx_host),
        else: System.delete_env("PHX_HOST")
    end)

    :ok
  end

  describe "check_origin?/1" do
    test "returns true when CHECK_ORIGIN is false" do
      System.put_env("CHECK_ORIGIN", "false")
      assert Endpoint.check_origin?(%URI{host: "arbitrary-host.com"})
    end

    test "allows origins matching CHECK_ORIGIN list and rejects non-matching" do
      System.put_env("CHECK_ORIGIN", "https://allowed.com, //secondary.org:8443")
      assert Endpoint.check_origin?(%URI{host: "allowed.com"})
      assert Endpoint.check_origin?(%URI{host: "secondary.org"})
      refute Endpoint.check_origin?(%URI{host: "unauthorized.com"})
    end

    test "allows private LAN and Tailscale CGNAT ranges when PHX_HOST is configured" do
      System.delete_env("CHECK_ORIGIN")
      System.put_env("PHX_HOST", "vpn.example.com")

      # Configured host
      assert Endpoint.check_origin?(%URI{host: "vpn.example.com"})

      # Localhost & Loopback
      assert Endpoint.check_origin?(%URI{host: "localhost"})
      assert Endpoint.check_origin?(%URI{host: "127.0.0.1"})
      assert Endpoint.check_origin?(%URI{host: "::1"})

      # Tailscale CGNAT (100.64.0.0/10)
      assert Endpoint.check_origin?(%URI{host: "100.64.0.1"})
      assert Endpoint.check_origin?(%URI{host: "100.100.50.25"})
      assert Endpoint.check_origin?(%URI{host: "100.127.255.254"})

      # Private LAN (10/8, 172.16/12, 192.168/16)
      assert Endpoint.check_origin?(%URI{host: "10.0.1.2"})
      assert Endpoint.check_origin?(%URI{host: "172.20.10.5"})
      assert Endpoint.check_origin?(%URI{host: "192.168.1.100"})

      # Rejects untrusted external domain or public IP outside allowed
      refute Endpoint.check_origin?(%URI{host: "evil-site.com"})
      refute Endpoint.check_origin?(%URI{host: "8.8.8.8"})
    end

    test "returns false for invalid or missing host structure" do
      refute Endpoint.check_origin?(nil)
      refute Endpoint.check_origin?(%URI{host: nil})
      refute Endpoint.check_origin?("not_a_uri_struct")
    end
  end
end
