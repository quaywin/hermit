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
    changeset = DnsConfig.changeset(%DnsConfig{}, %{
      upstream_dns: "1.1.1.1, 8.8.8.8",
      custom_rules: [
        %{"domain" => "bypass.domain.com", "action" => "bypass"},
        %{"domain" => "block.domain.net", "action" => "block"},
        %{"domain" => "redirect.me", "action" => "redirect", "value" => "192.168.1.1"}
      ]
    })
    assert changeset.valid?

    # 2. Invalid upstream IP format
    changeset = DnsConfig.changeset(%DnsConfig{}, %{
      upstream_dns: "invalid-ip, 8.8.8.8",
      custom_rules: []
    })
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :upstream_dns)

    # 3. Invalid custom rule format (missing domain)
    changeset = DnsConfig.changeset(%DnsConfig{}, %{
      upstream_dns: "1.1.1.1",
      custom_rules: [
        %{"action" => "block"}
      ]
    })
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :custom_rules)
  end

  test "DnsWorker monitors global config enabled status and syncs state in mock mode" do
    # Ensure starting in stopped state
    {:ok, _} = DnsConfig.update_global(%{enabled: false})
    {:ok, _} = DnsWorker.sync_state()
    {status, ip, _} = DnsWorker.get_status()
    assert status == :stopped
    assert is_nil(ip)

    # Enable global DNS config
    {:ok, _} = DnsConfig.update_global(%{enabled: true})
    {:ok, _} = DnsWorker.sync_state()
    {status, ip, _} = DnsWorker.get_status()
    assert status == :running
    assert ip == "100.64.0.100"

    # Disable it again
    {:ok, _} = DnsConfig.update_global(%{enabled: false})
    {:ok, _} = DnsWorker.sync_state()
    {status, ip, _} = DnsWorker.get_status()
    assert status == :stopped
    assert is_nil(ip)
  end
end
