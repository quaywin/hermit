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

  describe "Providers.tailscale_global_resolvers/1" do
    alias Hermit.Dns.Providers

    test "maps Control D UDP and DoH presets to a single Control D IP while preserving dual-IP for other providers" do
      assert Providers.tailscale_global_resolvers("76.76.2.2, 76.76.10.2") ==
               {:ok, ["76.76.2.2"]}

      assert Providers.tailscale_global_resolvers("https://freedns.controld.com/p2") ==
               {:ok, ["76.76.2.2"]}

      assert Providers.tailscale_global_resolvers("https://dns.adguard-dns.com/dns-query") ==
               {:ok, ["94.140.14.14", "94.140.15.15"]}
    end

    test "accepts custom IPs, IP:53, and Tailscale-supported custom DoH URLs (deduping NextDNS/Control D)" do
      assert Providers.tailscale_global_resolvers("1.1.1.1:53, 8.8.8.8") ==
               {:ok, ["1.1.1.1", "8.8.8.8"]}

      assert Providers.tailscale_global_resolvers("https://dns.controld.com/abc123") ==
               {:ok, ["https://dns.controld.com/abc123"]}

      assert Providers.tailscale_global_resolvers(
               "https://dns.nextdns.io/f00bar, https://dns.nextdns.io/bazqux"
             ) == {:ok, ["https://dns.nextdns.io/f00bar"]}
    end

    test "triggers fallback_global for Control D Community Lists and unsupported custom DoH URLs" do
      assert Providers.tailscale_global_resolvers("https://freedns.controld.com/x-hagezi-pro") ==
               {:fallback_global, :unsupported_doh}

      assert Providers.tailscale_global_resolvers("https://sky.rethinkdns.com/1:AA==") ==
               {:fallback_global, :unsupported_upstream}

      assert Providers.tailscale_global_resolvers("") == {:fallback_global, :empty_upstream}
    end
  end

  describe "collect_split_dns_domains/2 and build_sync_plan/2" do
    test "merges Services, Custom Rules, and extra SNI domains, strips wildcards, and prunes redundant subdomains" do
      config = %{
        tailscale_dns_mode: "split",
        upstream_dns: "76.76.2.2, 76.76.10.2",
        services: %{
          "netflix" => %{"action" => "route_tunnel", "pair_id" => "us-1"},
          "spotify" => %{"action" => "bypass"}
        },
        custom_rules: [
          %{"domain" => "*.Example.COM, api.netflix.com", "action" => "route_tunnel"},
          %{"domain" => "ads.tracker.org", "action" => "block"},
          %{"domain" => "bank.local.com", "action" => "bypass"},
          %{"domain" => "corp.internal", "action" => "forward_dns", "value" => "10.0.0.53"}
        ]
      }

      domains = DnsWorker.collect_split_dns_domains(config, ["*.custom-sni.dev", "bad_entry"])

      assert "netflix.com" in domains
      assert "nflxvideo.net" in domains
      assert "spotify.com" in domains
      assert "example.com" in domains
      assert "ads.tracker.org" in domains
      assert "bank.local.com" in domains
      assert "corp.internal" in domains
      assert "custom-sni.dev" in domains
      # api.netflix.com is pruned because parent netflix.com is already in splitDNS
      refute "api.netflix.com" in domains
      refute "bad_entry" in domains
    end

    test "build_sync_plan returns split plan for supported upstreams and falls back to global for community DoH" do
      split_config = %{
        tailscale_dns_mode: "split",
        upstream_dns: "https://freedns.controld.com/p2",
        services: %{},
        custom_rules: [%{"domain" => "openai.com", "action" => "route_tunnel"}]
      }

      plan = DnsWorker.build_sync_plan(split_config, [])
      assert plan.mode == :split
      assert plan.fallback_reason == nil
      assert plan.upstream_resolvers == ["76.76.2.2"]
      assert plan.split_domains == ["openai.com"]

      fallback_config = %{
        split_config
        | upstream_dns: "https://freedns.controld.com/x-hagezi-pro"
      }

      fb_plan = DnsWorker.build_sync_plan(fallback_config, [])
      assert fb_plan.mode == :global
      assert fb_plan.fallback_reason == :unsupported_doh
    end
  end

  describe "Split DNS /dns/configuration payload builders and sync" do
    test "build_split_dns_configuration sets direct upstreams, updates splitDNS, and preserves other entries" do
      current = %{
        "nameservers" => [%{"address" => "100.64.0.99", "useWithExitNode" => true}],
        "splitDNS" => %{
          "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}],
          "stale.hermit.com" => [%{"address" => "100.64.0.99", "useWithExitNode" => true}]
        },
        "searchPaths" => ["internal.corp"],
        "preferences" => %{"magicDNS" => true, "overrideLocalDNS" => false}
      }

      payload =
        DnsWorker.build_split_dns_configuration(
          current,
          "100.64.0.99",
          ["76.76.2.2", "76.76.10.2"],
          ["netflix.com", "openai.com"]
        )

      assert payload["nameservers"] == [
               %{"address" => "76.76.2.2", "useWithExitNode" => true},
               %{"address" => "76.76.10.2", "useWithExitNode" => true}
             ]

      assert payload["splitDNS"] == %{
               "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}],
               "netflix.com" => [%{"address" => "100.64.0.99", "useWithExitNode" => true}],
               "openai.com" => [%{"address" => "100.64.0.99", "useWithExitNode" => true}]
             }

      refute Map.has_key?(payload["splitDNS"], "stale.hermit.com")
      assert payload["preferences"] == %{"magicDNS" => true, "overrideLocalDNS" => true}
      assert payload["searchPaths"] == ["internal.corp"]
    end

    test "sync_tailscale_dns_via_api syncs Split DNS via /dns/configuration and cleans up on global switch & clear" do
      test_pid = self()

      plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = if raw_body == "", do: nil, else: Jason.decode!(raw_body)
        send(test_pid, {:http_call, conn.method, conn.request_path, decoded})

        case {conn.method, conn.request_path} do
          {"GET", "/api/v2/tailnet/my-tailnet/dns/configuration"} ->
            Req.Test.json(conn, %{
              "nameservers" => [],
              "splitDNS" => %{
                "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}],
                "old.hermit.dev" => [%{"address" => "100.64.0.99", "useWithExitNode" => true}]
              },
              "preferences" => %{"magicDNS" => true, "overrideLocalDNS" => false}
            })

          {"POST", "/api/v2/tailnet/my-tailnet/dns/configuration"} ->
            Req.Test.json(conn, decoded)
        end
      end

      split_plan = %{
        mode: :split,
        fallback_reason: nil,
        upstream_resolvers: ["76.76.2.2", "76.76.10.2"],
        split_domains: ["netflix.com"]
      }

      assert {:ok, :updated} =
               DnsWorker.sync_tailscale_dns_via_api("100.64.0.99", "my-tailnet", "tok",
                 plan: split_plan,
                 plug: plug,
                 retry: false
               )

      assert_received {:http_call, "POST", "/api/v2/tailnet/my-tailnet/dns/configuration",
                       payload}

      assert payload["nameservers"] == [
               %{"address" => "76.76.2.2", "useWithExitNode" => true},
               %{"address" => "76.76.10.2", "useWithExitNode" => true}
             ]

      assert payload["splitDNS"] == %{
               "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}],
               "netflix.com" => [%{"address" => "100.64.0.99", "useWithExitNode" => true}]
             }

      # Switching back to Global removes Hermit IP from splitDNS while preserving internal.corp
      global_payload = DnsWorker.build_updated_dns_configuration(payload, "100.64.0.99")

      assert global_payload["splitDNS"] == %{
               "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}]
             }

      # Clearing removes Hermit IP from both nameservers and splitDNS
      cleared = DnsWorker.build_cleared_dns_configuration(payload, "100.64.0.99")

      assert cleared["splitDNS"] == %{
               "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}]
             }
    end

    test "falls back to legacy /dns/nameservers + /dns/split-dns when /dns/configuration returns 404" do
      test_pid = self()

      plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = if raw_body == "", do: nil, else: Jason.decode!(raw_body)
        send(test_pid, {:http_call, conn.method, conn.request_path, decoded})

        case {conn.method, conn.request_path} do
          {"GET", "/api/v2/tailnet/-/dns/configuration"} ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "not found"})

          {"POST", "/api/v2/tailnet/-/dns/nameservers"} ->
            Req.Test.json(conn, decoded)

          {"POST", "/api/v2/tailnet/-/dns/preferences"} ->
            Req.Test.json(conn, decoded)

          {"GET", "/api/v2/tailnet/-/dns/split-dns"} ->
            Req.Test.json(conn, %{
              "internal.corp" => ["10.0.0.53"],
              "stale.hermit.com" => ["100.64.0.99"]
            })

          {"PUT", "/api/v2/tailnet/-/dns/split-dns"} ->
            Req.Test.json(conn, decoded)
        end
      end

      split_plan = %{
        mode: :split,
        fallback_reason: nil,
        upstream_resolvers: ["76.76.2.2", "76.76.10.2"],
        split_domains: ["openai.com"]
      }

      assert {:ok, :updated} =
               DnsWorker.sync_tailscale_dns_via_api("100.64.0.99", "-", "tok",
                 plan: split_plan,
                 plug: plug,
                 retry: false
               )

      assert_received {:http_call, "POST", "/api/v2/tailnet/-/dns/nameservers",
                       %{"dns" => ["76.76.2.2", "76.76.10.2"]}}

      assert_received {:http_call, "PUT", "/api/v2/tailnet/-/dns/split-dns",
                       %{
                         "internal.corp" => ["10.0.0.53"],
                         "openai.com" => ["100.64.0.99"]
                       }}
    end

    test "switching Split -> Global strips Control D upstream IPs while preserving HA Hermit peer and non-Hermit splitDNS" do
      test_pid = self()

      plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = if raw_body == "", do: nil, else: Jason.decode!(raw_body)
        send(test_pid, {:http_call, conn.method, conn.request_path, decoded})

        case {conn.method, conn.request_path} do
          {"GET", "/api/v2/tailnet/my-tailnet/dns/configuration"} ->
            Req.Test.json(conn, %{
              "nameservers" => [
                %{"address" => "76.76.2.2", "useWithExitNode" => true},
                %{"address" => "76.76.10.2", "useWithExitNode" => true},
                %{"address" => "100.64.0.20", "useWithExitNode" => true}
              ],
              "splitDNS" => %{
                "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}],
                "netflix.com" => [%{"address" => "100.64.0.99", "useWithExitNode" => true}]
              },
              "preferences" => %{"magicDNS" => true, "overrideLocalDNS" => true}
            })

          {"POST", "/api/v2/tailnet/my-tailnet/dns/configuration"} ->
            Req.Test.json(conn, decoded)
        end
      end

      global_config = %{
        tailscale_dns_mode: "global",
        upstream_dns: "76.76.2.2, 76.76.10.2",
        services: %{"netflix" => %{"action" => "route_tunnel", "pair_id" => "us-1"}},
        custom_rules: []
      }

      plan = DnsWorker.build_sync_plan(global_config, [], ["76.76.2.2", "76.76.10.2"])
      assert plan.mode == :global
      assert "76.76.2.2" in plan.strip_resolvers
      assert "76.76.10.2" in plan.strip_resolvers

      assert {:ok, :updated} =
               DnsWorker.sync_tailscale_dns_via_api("100.64.0.99", "my-tailnet", "tok",
                 plan: plan,
                 plug: plug,
                 retry: false
               )

      assert_received {:http_call, "POST", "/api/v2/tailnet/my-tailnet/dns/configuration",
                       payload}

      assert payload["nameservers"] == [
               %{"address" => "100.64.0.20", "useWithExitNode" => true},
               %{"address" => "100.64.0.99", "useWithExitNode" => true}
             ]

      assert payload["splitDNS"] == %{
               "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}]
             }
    end

    test "switching Split (Control D) -> Community DoH fallback strips Control D IPs and enables Global DNS" do
      test_pid = self()

      plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = if raw_body == "", do: nil, else: Jason.decode!(raw_body)
        send(test_pid, {:http_call, conn.method, conn.request_path, decoded})

        case {conn.method, conn.request_path} do
          {"GET", "/api/v2/tailnet/-/dns/configuration"} ->
            Req.Test.json(conn, %{
              "nameservers" => [
                %{"address" => "76.76.2.2", "useWithExitNode" => true},
                %{"address" => "76.76.10.2", "useWithExitNode" => true}
              ],
              "splitDNS" => %{
                "openai.com" => [%{"address" => "100.64.0.99", "useWithExitNode" => true}]
              },
              "preferences" => %{"magicDNS" => true, "overrideLocalDNS" => true}
            })

          {"POST", "/api/v2/tailnet/-/dns/configuration"} ->
            Req.Test.json(conn, decoded)
        end
      end

      community_config = %{
        tailscale_dns_mode: "split",
        upstream_dns: "https://freedns.controld.com/x-hagezi-pro",
        services: %{},
        custom_rules: [%{"domain" => "openai.com", "action" => "route_tunnel"}]
      }

      plan = DnsWorker.build_sync_plan(community_config, [], ["76.76.2.2", "76.76.10.2"])
      assert plan.mode == :global
      assert plan.fallback_reason == :unsupported_doh

      assert {:ok, :updated} =
               DnsWorker.sync_tailscale_dns_via_api("100.64.0.99", "-", "tok",
                 plan: plan,
                 plug: plug,
                 retry: false
               )

      assert_received {:http_call, "POST", "/api/v2/tailnet/-/dns/configuration", payload}

      assert payload["nameservers"] == [
               %{"address" => "100.64.0.99", "useWithExitNode" => true}
             ]

      assert payload["splitDNS"] == %{}
    end

    test "clear_tailscale_dns_via_api with strip_resolvers cleans up both upstream IPs and Hermit splitDNS entries" do
      test_pid = self()

      plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = if raw_body == "", do: nil, else: Jason.decode!(raw_body)
        send(test_pid, {:http_call, conn.method, conn.request_path, decoded})

        case {conn.method, conn.request_path} do
          {"GET", "/api/v2/tailnet/-/dns/configuration"} ->
            Req.Test.json(conn, %{
              "nameservers" => [
                %{"address" => "76.76.2.2", "useWithExitNode" => true},
                %{"address" => "76.76.10.2", "useWithExitNode" => true}
              ],
              "splitDNS" => %{
                "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}],
                "netflix.com" => [%{"address" => "100.64.0.99", "useWithExitNode" => true}]
              },
              "preferences" => %{"magicDNS" => true, "overrideLocalDNS" => true}
            })

          {"POST", "/api/v2/tailnet/-/dns/configuration"} ->
            Req.Test.json(conn, decoded)
        end
      end

      assert {:ok, :cleared} =
               DnsWorker.clear_tailscale_dns_via_api("100.64.0.99", "-", "tok",
                 strip_resolvers: ["76.76.2.2", "76.76.10.2"],
                 plug: plug,
                 retry: false
               )

      assert_received {:http_call, "POST", "/api/v2/tailnet/-/dns/configuration", payload}
      assert payload["nameservers"] == []

      assert payload["splitDNS"] == %{
               "internal.corp" => [%{"address" => "10.0.0.53", "useWithExitNode" => false}]
             }

      assert payload["preferences"] == %{"magicDNS" => true, "overrideLocalDNS" => false}
    end
  end
end
