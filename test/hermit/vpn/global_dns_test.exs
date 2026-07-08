defmodule Hermit.Vpn.GlobalDnsTest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.DnsConfig
  alias Hermit.Vpn.DnsWorker

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

  test "DnsConfig validates global settings, upstream DNS, and custom rules" do
    # 1. Valid settings
    changeset =
      DnsConfig.changeset(%DnsConfig{}, %{
        upstream_dns: "1.1.1.1, 8.8.8.8",
        custom_rules: [
          %{"domain" => "bypass.domain.com", "action" => "bypass"},
          %{"domain" => "block.domain.net", "action" => "block"},
          %{"domain" => "redirect.me", "action" => "redirect", "value" => "192.168.1.1"}
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

  test "DnsWorker manages status and lifecycle per inbound profile in mock mode" do
    # Create an inbound profile
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "P1",
        type: "tailscale",
        config: %{"ts_auth_key" => "k1"}
      })

    # Start in stopped state because no process exists in registry yet
    {status, ip, _} = DnsWorker.get_status(profile.id)
    assert status == :stopped
    assert is_nil(ip)

    # Enabling without inbound profile should fail validation if enabled is true
    changeset = DnsConfig.changeset(%DnsConfig{}, %{enabled: true, inbound_profile_id: nil})
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :inbound_profile_id)

    # Configure DNS config with inbound profile
    {:ok, config} = DnsConfig.update_for_profile(profile.id, %{enabled: true})
    assert config.inbound_profile_id == profile.id

    # Start via DnsSupervisor
    {:ok, {worker_pid, server_pid}} = Hermit.Vpn.DnsSupervisor.start_dns(profile.id)
    assert is_pid(worker_pid)
    assert is_pid(server_pid)

    # Status should now be running
    {status, ip, _} = wait_for_status(profile.id, :running)
    assert status == :running
    assert ip == "100.64.0.100"

    # Sync state
    assert {:ok, :already_synced} = DnsWorker.sync_state(profile.id)

    # Stop it
    :ok = Hermit.Vpn.DnsSupervisor.stop_dns(profile.id)

    # Status should be stopped
    {status, ip, _} = DnsWorker.get_status(profile.id)
    assert status == :stopped
    assert is_nil(ip)
  end

  test "DnsWorker processes can run concurrently for multiple profiles" do
    # Create two profiles
    {:ok, p1} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "Profile 1",
        type: "tailscale",
        config: %{"ts_auth_key" => "k1"}
      })

    {:ok, p2} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "Profile 2",
        type: "tailscale",
        config: %{"ts_auth_key" => "k2"}
      })

    # Configure both
    {:ok, _c1} = DnsConfig.update_for_profile(p1.id, %{enabled: true})
    {:ok, _c2} = DnsConfig.update_for_profile(p2.id, %{enabled: true})

    # Start both
    {:ok, _} = Hermit.Vpn.DnsSupervisor.start_dns(p1.id)
    {:ok, _} = Hermit.Vpn.DnsSupervisor.start_dns(p2.id)

    # Verify both are running independently
    {s1, ip1, _} = wait_for_status(p1.id, :running)
    assert s1 == :running
    assert ip1 == "100.64.0.100"

    {s2, ip2, _} = wait_for_status(p2.id, :running)
    assert s2 == :running
    assert ip2 == "100.64.0.100"

    # Stop both
    :ok = Hermit.Vpn.DnsSupervisor.stop_dns(p1.id)
    :ok = Hermit.Vpn.DnsSupervisor.stop_dns(p2.id)

    assert {s1_after, _, _} = DnsWorker.get_status(p1.id)
    assert s1_after == :stopped

    assert {s2_after, _, _} = DnsWorker.get_status(p2.id)
    assert s2_after == :stopped
  end

  test "DnsWorker handles dynamic toggle of tailscale_override_dns while running" do
    # 1. Setup profile and enable DNS
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "Profile Dynamic DNS",
        type: "tailscale",
        config: %{"ts_auth_key" => "k3"}
      })

    {:ok, _config} =
      DnsConfig.update_for_profile(profile.id, %{enabled: true, tailscale_override_dns: false})

    # Start DNS
    {:ok, _} = Hermit.Vpn.DnsSupervisor.start_dns(profile.id)
    assert {s, _ip, _} = wait_for_status(profile.id, :running)
    assert s == :running

    # 2. Toggle tailscale_override_dns to true
    {:ok, _config} = DnsConfig.update_for_profile(profile.id, %{tailscale_override_dns: true})
    assert {:ok, :updated_dns_integration} = DnsWorker.sync_state(profile.id)

    # 3. Toggle tailscale_override_dns to false
    {:ok, _config} = DnsConfig.update_for_profile(profile.id, %{tailscale_override_dns: false})
    assert {:ok, :updated_dns_integration} = DnsWorker.sync_state(profile.id)

    # 4. Sync again without changes
    assert {:ok, :already_synced} = DnsWorker.sync_state(profile.id)

    # Cleanup
    :ok = Hermit.Vpn.DnsSupervisor.stop_dns(profile.id)
  end

  defp wait_for_status(profile_id, expected_status, retries \\ 20) do
    case DnsWorker.get_status(profile_id) do
      {^expected_status, ip, err} ->
        {expected_status, ip, err}

      _ ->
        if retries == 0 do
          DnsWorker.get_status(profile_id)
        else
          Process.sleep(100)
          wait_for_status(profile_id, expected_status, retries - 1)
        end
    end
  end
end
