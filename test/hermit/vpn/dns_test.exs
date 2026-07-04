defmodule Hermit.Vpn.DnsTest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.VpnPair
  alias Hermit.Vpn.DnsLogReceiver

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

  test "VpnPair validates dns_config maps and rules" do
    # 1. Valid dns_config map with defaults
    changeset = VpnPair.changeset(%VpnPair{}, %{
      pair_id: "dns_test_pair",
      inbound_profile_id: 1,
      outbound_profile_id: 1,
      dns_config: %{
        "enabled" => true,
        "block_ads" => true,
        "block_adult" => false,
        "upstream_dns" => "1.1.1.1, 8.8.8.8",
        "custom_rules" => [
          %{"domain" => "google.com", "action" => "bypass"},
          %{"domain" => "ad.doubleclick.net", "action" => "block"},
          %{"domain" => "my-home.local", "action" => "redirect", "value" => "10.0.0.5"}
        ]
      }
    })
    assert changeset.valid?

    # 2. Invalid custom rule format (missing domain)
    changeset = VpnPair.changeset(%VpnPair{}, %{
      pair_id: "dns_test_pair",
      inbound_profile_id: 1,
      outbound_profile_id: 1,
      dns_config: %{
        "enabled" => true,
        "custom_rules" => [
          %{"action" => "block"}
        ]
      }
    })
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :dns_config)

    # 3. Invalid custom rule action (unsupported action)
    changeset = VpnPair.changeset(%VpnPair{}, %{
      pair_id: "dns_test_pair",
      inbound_profile_id: 1,
      outbound_profile_id: 1,
      dns_config: %{
        "enabled" => true,
        "custom_rules" => [
          %{"domain" => "test.com", "action" => "unknown"}
        ]
      }
    })
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :dns_config)
  end

  test "DnsLogReceiver listens on UDP and broadcasts received logs" do
    # Subscribe to test logging PubSub
    pair_id = "test_pair_dns_log"
    topic = "dns_logs:#{pair_id}"
    Phoenix.PubSub.subscribe(Hermit.PubSub, topic)

    # Prepare mock log payload
    log = %{
      "pair_id" => pair_id,
      "domain" => "google.com",
      "type" => "A",
      "status" => "resolved",
      "answer" => "142.250.190.46",
      "duration" => 25,
      "timestamp" => System.system_time(:second)
    }
    
    # Send mock log by directly sending message to the DnsLogReceiver process
    send(DnsLogReceiver, {:udp, nil, nil, nil, Jason.encode!(log)})

    # Assert log message was broadcasted to PubSub
    assert_receive {:dns_log, received_log}, 1000
    assert received_log["pair_id"] == pair_id
    assert received_log["domain"] == "google.com"
    assert received_log["status"] == "resolved"

    # Assert it was cached in ETS
    cached = DnsLogReceiver.get_recent_logs(pair_id)
    assert length(cached) == 1
    assert hd(cached)["domain"] == "google.com"

    # Test clear_logs API
    DnsLogReceiver.clear_logs(pair_id)
    # The cast is async, sleep briefly
    Process.sleep(50)
    assert DnsLogReceiver.get_recent_logs(pair_id) == []
  end
end
