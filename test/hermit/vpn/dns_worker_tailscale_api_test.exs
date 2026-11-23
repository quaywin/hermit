defmodule Hermit.Vpn.DnsWorkerTailscaleApiTest do
  use ExUnit.Case, async: true

  alias Hermit.Vpn.DnsWorker

  describe "upsert_config_resolver/2 and remove_config_resolver/2" do
    test "appends new resolver with useWithExitNode enabled while preserving existing resolvers" do
      existing = [%{"address" => "1.1.1.1", "useWithExitNode" => false}]

      assert DnsWorker.upsert_config_resolver(existing, "100.64.0.10") == [
               %{"address" => "1.1.1.1", "useWithExitNode" => false},
               %{"address" => "100.64.0.10", "useWithExitNode" => true}
             ]
    end

    test "upgrades existing matching resolver in place to useWithExitNode: true" do
      existing = [
        %{"address" => "100.64.0.10", "useWithExitNode" => false},
        %{"address" => "8.8.8.8", "useWithExitNode" => false}
      ]

      assert DnsWorker.upsert_config_resolver(existing, "100.64.0.10") == [
               %{"address" => "100.64.0.10", "useWithExitNode" => true},
               %{"address" => "8.8.8.8", "useWithExitNode" => false}
             ]
    end

    test "removes matching resolver while preserving others" do
      existing = [
        %{"address" => "100.64.0.10", "useWithExitNode" => true},
        %{"address" => "1.1.1.1", "useWithExitNode" => false}
      ]

      assert DnsWorker.remove_config_resolver(existing, "100.64.0.10") == [
               %{"address" => "1.1.1.1", "useWithExitNode" => false}
             ]
    end
  end

  describe "sync_tailscale_dns_via_api/4" do
    test "uses /dns/configuration to enable useWithExitNode and overrideLocalDNS while preserving other fields" do
      test_pid = self()

      plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = if raw_body == "", do: nil, else: Jason.decode!(raw_body)
        send(test_pid, {:http_call, conn.method, conn.request_path, decoded})

        case {conn.method, conn.request_path} do
          {"GET", "/api/v2/tailnet/my-tailnet/dns/configuration"} ->
            Req.Test.json(conn, %{
              "nameservers" => [%{"address" => "1.1.1.1", "useWithExitNode" => false}],
              "splitDNS" => %{
                "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}]
              },
              "searchPaths" => ["internal.corp"],
              "preferences" => %{"magicDNS" => true, "overrideLocalDNS" => false}
            })

          {"POST", "/api/v2/tailnet/my-tailnet/dns/configuration"} ->
            Req.Test.json(conn, decoded)
        end
      end

      assert {:ok, :updated} =
               DnsWorker.sync_tailscale_dns_via_api("100.64.0.99", "my-tailnet", "tok",
                 plug: plug,
                 retry: false
               )

      assert_received {:http_call, "GET", "/api/v2/tailnet/my-tailnet/dns/configuration", nil}

      assert_received {:http_call, "POST", "/api/v2/tailnet/my-tailnet/dns/configuration",
                       payload}

      assert payload["nameservers"] == [
               %{"address" => "1.1.1.1", "useWithExitNode" => false},
               %{"address" => "100.64.0.99", "useWithExitNode" => true}
             ]

      assert payload["preferences"] == %{"magicDNS" => true, "overrideLocalDNS" => true}
      assert payload["searchPaths"] == ["internal.corp"]

      assert payload["splitDNS"] == %{
               "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}]
             }
    end

    test "falls back to legacy /dns/nameservers and /dns/preferences when /dns/configuration returns 404" do
      test_pid = self()

      plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = if raw_body == "", do: nil, else: Jason.decode!(raw_body)
        send(test_pid, {:http_call, conn.method, conn.request_path, decoded})

        case {conn.method, conn.request_path} do
          {"GET", "/api/v2/tailnet/-/dns/configuration"} ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "not found"})

          {"GET", "/api/v2/tailnet/-/dns/nameservers"} ->
            Req.Test.json(conn, %{"dns" => ["1.1.1.1"]})

          {"POST", "/api/v2/tailnet/-/dns/nameservers"} ->
            Req.Test.json(conn, decoded)

          {"POST", "/api/v2/tailnet/-/dns/preferences"} ->
            Req.Test.json(conn, decoded)
        end
      end

      assert {:ok, :updated} =
               DnsWorker.sync_tailscale_dns_via_api("100.64.0.99", "-", "tok",
                 plug: plug,
                 retry: false
               )

      assert_received {:http_call, "GET", "/api/v2/tailnet/-/dns/configuration", nil}
      assert_received {:http_call, "GET", "/api/v2/tailnet/-/dns/nameservers", nil}

      assert_received {:http_call, "POST", "/api/v2/tailnet/-/dns/nameservers",
                       %{"dns" => ["1.1.1.1", "100.64.0.99"]}}

      assert_received {:http_call, "POST", "/api/v2/tailnet/-/dns/preferences",
                       %{"overrideLocalDNS" => true}}
    end

    test "returns 403 error immediately without fallback when OAuth scope is missing" do
      plug = fn conn ->
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "forbidden"})
      end

      assert {:error, {:http_error, 403, %{"message" => "forbidden"}}} =
               DnsWorker.sync_tailscale_dns_via_api("100.64.0.99", "-", "tok",
                 plug: plug,
                 retry: false
               )
    end
  end

  describe "clear_tailscale_dns_via_api/4" do
    test "removes target IP via /dns/configuration and disables overrideLocalDNS when empty" do
      test_pid = self()

      plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = if raw_body == "", do: nil, else: Jason.decode!(raw_body)
        send(test_pid, {:http_call, conn.method, conn.request_path, decoded})

        case {conn.method, conn.request_path} do
          {"GET", "/api/v2/tailnet/-/dns/configuration"} ->
            Req.Test.json(conn, %{
              "nameservers" => [%{"address" => "100.64.0.99", "useWithExitNode" => true}],
              "preferences" => %{"magicDNS" => true, "overrideLocalDNS" => true}
            })

          {"POST", "/api/v2/tailnet/-/dns/configuration"} ->
            Req.Test.json(conn, decoded)
        end
      end

      assert {:ok, :cleared} =
               DnsWorker.clear_tailscale_dns_via_api("100.64.0.99", "-", "tok",
                 plug: plug,
                 retry: false
               )

      assert_received {:http_call, "POST", "/api/v2/tailnet/-/dns/configuration", payload}
      assert payload["nameservers"] == []
      assert payload["preferences"] == %{"magicDNS" => true, "overrideLocalDNS" => false}
    end

    test "falls back to legacy endpoints when /dns/configuration is unavailable during clear" do
      test_pid = self()

      plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = if raw_body == "", do: nil, else: Jason.decode!(raw_body)
        send(test_pid, {:http_call, conn.method, conn.request_path, decoded})

        case {conn.method, conn.request_path} do
          {"GET", "/api/v2/tailnet/-/dns/configuration"} ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "not found"})

          {"GET", "/api/v2/tailnet/-/dns/nameservers"} ->
            Req.Test.json(conn, %{"dns" => ["100.64.0.99"]})

          {"POST", "/api/v2/tailnet/-/dns/nameservers"} ->
            Req.Test.json(conn, decoded)

          {"POST", "/api/v2/tailnet/-/dns/preferences"} ->
            Req.Test.json(conn, decoded)
        end
      end

      assert {:ok, :cleared} =
               DnsWorker.clear_tailscale_dns_via_api("100.64.0.99", "-", "tok",
                 plug: plug,
                 retry: false
               )

      assert_received {:http_call, "POST", "/api/v2/tailnet/-/dns/nameservers", %{"dns" => []}}

      assert_received {:http_call, "POST", "/api/v2/tailnet/-/dns/preferences",
                       %{"overrideLocalDNS" => false}}
    end
  end
end
