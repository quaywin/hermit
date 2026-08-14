defmodule Hermit.Vpn.DnsDdnsResolverTest do
  use HermitWeb.ConnCase, async: false
  alias Hermit.Vpn.DnsDdnsResolver
  alias Hermit.Vpn.DnsEndpoint
  alias Hermit.Vpn.DnsConfig

  test "lookup_endpoint_id returns :not_found for unknown IP" do
    assert DnsDdnsResolver.lookup_endpoint_id("192.168.1.99") == :not_found
  end

  test "trigger_sync resolves endpoints with ddns_hostname and stores in ETS cache" do
    profile =
      %DnsConfig{}
      |> DnsConfig.changeset(%{name: "Test DDNS Profile", upstream_dns: "1.1.1.1", custom_rules: []})
      |> Hermit.Repo.insert!()

    endpoint =
      %DnsEndpoint{}
      |> DnsEndpoint.changeset(%{
        name: "Home Router",
        enabled: true,
        dns_profile_id: profile.id,
        ddns_hostname: "localhost"
      })
      |> Hermit.Repo.insert!()

    DnsDdnsResolver.trigger_sync()

    # Wait briefly for sync cast to execute
    Process.sleep(200)

    # Localhost resolves to 127.0.0.1
    assert DnsDdnsResolver.lookup_endpoint_id("127.0.0.1") == {:ok, endpoint.id}

    map = DnsDdnsResolver.get_resolved_ddns_map()
    assert Map.has_key?(map, endpoint.id)
    assert map[endpoint.id].hostname == "localhost"
    assert map[endpoint.id].ip == "127.0.0.1"
  end
end
