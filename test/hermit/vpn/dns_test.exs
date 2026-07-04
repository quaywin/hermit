defmodule Hermit.Vpn.DnsTest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.DnsLogReceiver

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

  test "DnsLogReceiver enriches logs with client_ip and resolved client_name" do
    # Use numeric pair_id so get_profile_id/1 returns a valid integer directly
    pair_id = "999"
    topic = "dns_logs:#{pair_id}"
    Phoenix.PubSub.subscribe(Hermit.PubSub, topic)

    # 1. Send log without client_ip -> should default to sender IP (e.g. 127.0.0.1) and name "localhost"
    log1 = %{
      "pair_id" => pair_id,
      "domain" => "github.com",
      "type" => "A",
      "status" => "resolved",
      "answer" => "140.82.121.4",
      "duration" => 15,
      "timestamp" => System.system_time(:second)
    }

    # Simulate sending from localhost IP {127, 0, 0, 1}
    send(DnsLogReceiver, {:udp, nil, {127, 0, 0, 1}, nil, Jason.encode!(log1)})

    assert_receive {:dns_log, received_log1}, 1000
    assert received_log1["client_ip"] == "127.0.0.1"

    # Wait for the async task to populate the mock cache
    Process.sleep(50)

    # Send again to check that cached name is used
    send(DnsLogReceiver, {:udp, nil, {127, 0, 0, 1}, nil, Jason.encode!(log1)})
    assert_receive {:dns_log, received_log1_cached}, 1000
    assert received_log1_cached["client_name"] == "localhost"

    # 2. Send log with explicit mock client IP "100.64.0.5" -> should resolve to "mock-client"
    log2 = %{
      "pair_id" => pair_id,
      "client_ip" => "100.64.0.5",
      "domain" => "google.com",
      "type" => "A",
      "status" => "resolved",
      "answer" => "142.250.190.46",
      "duration" => 25,
      "timestamp" => System.system_time(:second)
    }

    send(DnsLogReceiver, {:udp, nil, {127, 0, 0, 1}, nil, Jason.encode!(log2)})
    Process.sleep(50)

    # Send again to use cached device name
    send(DnsLogReceiver, {:udp, nil, {127, 0, 0, 1}, nil, Jason.encode!(log2)})
    assert_receive {:dns_log, received_log2_cached}, 1000
    assert received_log2_cached["client_name"] == "mock-client"
  end
end
