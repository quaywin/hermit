defmodule Hermit.Vpn.GlobalDnsTest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.DnsConfig
  alias Hermit.Vpn.DnsEndpoint
  alias Hermit.Vpn.DnsWorker

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

  test "DnsConfig validates settings, upstream DNS, and custom rules" do
    # 1. Valid settings
    changeset =
      DnsConfig.changeset(%DnsConfig{}, %{
        upstream_dns: "1.1.1.1, 8.8.8.8",
        custom_rules: [
          %{"domain" => "bypass.domain.com", "action" => "bypass"},
          %{"domain" => "block.domain.net", "action" => "block"},
          %{"domain" => "redirect.me", "action" => "redirect", "value" => "192.168.1.1"},
          %{
            "domain" => "company.local",
            "action" => "forward_dns",
            "value" => "10.0.0.1",
            "proxy_pair_id" => "wg_company"
          }
        ]
      })

    assert changeset.valid?

    # 2. Invalid upstream IP format
    changeset =
      DnsConfig.changeset(%DnsConfig{}, %{
        upstream_dns: "invalid-ip, 8.8.8.8",
        custom_rules: []
      })

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :upstream_dns)

    # 3. Invalid custom rule format (missing domain)
    changeset =
      DnsConfig.changeset(%DnsConfig{}, %{
        upstream_dns: "1.1.1.1",
        custom_rules: [
          %{"action" => "block"}
        ]
      })

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :custom_rules)
  end

  test "DnsWorker manages status and lifecycle per endpoint in mock mode" do
    # Create inbound profile
    {:ok, inbound} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "P1",
        type: "tailscale",
        config: %{"ts_auth_key" => "k1"}
      })

    # Create DNS Config
    {:ok, config} =
      Hermit.Repo.insert(%DnsConfig{
        name: "DNS Profile P1",
        enabled: true,
        upstream_dns: "1.1.1.1",
        custom_rules: []
      })

    # Create DNS Endpoint via changeset to generate doh_token
    {:ok, endpoint} =
      %DnsEndpoint{}
      |> DnsEndpoint.changeset(%{
        name: "Endpoint P1",
        dns_profile_id: config.id,
        inbound_profile_id: inbound.id,
        enabled: true
      })
      |> Hermit.Repo.insert()

    # Start in stopped state because no process exists in registry yet
    {status, ip, _} = DnsWorker.get_status(endpoint.id)
    assert status == :stopped
    assert is_nil(ip)

    # Start via DnsSupervisor
    {:ok, {worker_pid, server_pid}} = Hermit.Vpn.DnsSupervisor.start_dns(endpoint.id, inbound.id)
    assert is_pid(worker_pid)
    assert is_pid(server_pid)

    # Status should now be running
    {status, ip, _} = wait_for_status(endpoint.id, :running)
    assert status == :running
    assert ip == "100.64.0.100"

    # Sync state
    assert {:ok, :already_synced} = DnsWorker.sync_state(endpoint.id)

    # Stop it
    :ok = Hermit.Vpn.DnsSupervisor.stop_dns(endpoint.id)

    # Status should be stopped
    {status, ip, _} = DnsWorker.get_status(endpoint.id)
    assert status == :stopped
    assert is_nil(ip)
  end

  test "DnsWorker processes can run concurrently for multiple endpoints" do
    # Create Inbound Profiles
    {:ok, i1} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "Inbound 1",
        type: "tailscale",
        config: %{"ts_auth_key" => "k1"}
      })

    {:ok, i2} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "Inbound 2",
        type: "tailscale",
        config: %{"ts_auth_key" => "k2"}
      })

    # Create DNS Configs
    {:ok, c1} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Config 1",
        enabled: true,
        upstream_dns: "1.1.1.1",
        custom_rules: []
      })

    {:ok, c2} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Config 2",
        enabled: true,
        upstream_dns: "8.8.8.8",
        custom_rules: []
      })

    # Create DNS Endpoints via changeset to generate doh_token
    {:ok, e1} =
      %DnsEndpoint{}
      |> DnsEndpoint.changeset(%{
        name: "Endpoint 1",
        dns_profile_id: c1.id,
        inbound_profile_id: i1.id,
        enabled: true
      })
      |> Hermit.Repo.insert()

    {:ok, e2} =
      %DnsEndpoint{}
      |> DnsEndpoint.changeset(%{
        name: "Endpoint 2",
        dns_profile_id: c2.id,
        inbound_profile_id: i2.id,
        enabled: true
      })
      |> Hermit.Repo.insert()

    # Start both
    {:ok, _} = Hermit.Vpn.DnsSupervisor.start_dns(e1.id, i1.id)
    {:ok, _} = Hermit.Vpn.DnsSupervisor.start_dns(e2.id, i2.id)

    # Verify both are running independently
    {s1, ip1, _} = wait_for_status(e1.id, :running)
    assert s1 == :running
    assert ip1 == "100.64.0.100"

    {s2, ip2, _} = wait_for_status(e2.id, :running)
    assert s2 == :running
    assert ip2 == "100.64.0.100"

    # Stop both
    :ok = Hermit.Vpn.DnsSupervisor.stop_dns(e1.id)
    :ok = Hermit.Vpn.DnsSupervisor.stop_dns(e2.id)

    assert {s1_after, _, _} = DnsWorker.get_status(e1.id)
    assert s1_after == :stopped

    assert {s2_after, _, _} = DnsWorker.get_status(e2.id)
    assert s2_after == :stopped
  end

  test "DnsWorker handles dynamic toggle of tailscale_override_dns while running" do
    {:ok, inbound} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "Inbound Dynamic DNS",
        type: "tailscale",
        config: %{"ts_auth_key" => "k3"}
      })

    {:ok, config} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Dynamic Profile",
        enabled: true,
        tailscale_override_dns: false,
        upstream_dns: "1.1.1.1",
        custom_rules: []
      })

    # Create DNS Endpoint via changeset to generate doh_token
    {:ok, endpoint} =
      %DnsEndpoint{}
      |> DnsEndpoint.changeset(%{
        name: "Dynamic Endpoint",
        dns_profile_id: config.id,
        inbound_profile_id: inbound.id,
        enabled: true
      })
      |> Hermit.Repo.insert()

    # Start DNS
    {:ok, _} = Hermit.Vpn.DnsSupervisor.start_dns(endpoint.id, inbound.id)
    assert {s, _ip, _} = wait_for_status(endpoint.id, :running)
    assert s == :running

    # 2. Toggle tailscale_override_dns to true
    {:ok, _c_updated} =
      DnsConfig.update_for_endpoint(endpoint.id, %{tailscale_override_dns: true})

    assert {:ok, :updated_dns_integration} = DnsWorker.sync_state(endpoint.id)

    # 3. Toggle tailscale_override_dns to false
    {:ok, _c_updated2} =
      DnsConfig.update_for_endpoint(endpoint.id, %{tailscale_override_dns: false})

    assert {:ok, :updated_dns_integration} = DnsWorker.sync_state(endpoint.id)

    # 4. Sync again without changes
    assert {:ok, :already_synced} = DnsWorker.sync_state(endpoint.id)

    # Cleanup
    :ok = Hermit.Vpn.DnsSupervisor.stop_dns(endpoint.id)
  end

  defp wait_for_status(endpoint_id, expected_status, retries \\ 20) do
    case DnsWorker.get_status(endpoint_id) do
      {^expected_status, ip, err} ->
        {expected_status, ip, err}

      _ ->
        if retries == 0 do
          DnsWorker.get_status(endpoint_id)
        else
          Process.sleep(100)
          wait_for_status(endpoint_id, expected_status, retries - 1)
        end
    end
  end
end
