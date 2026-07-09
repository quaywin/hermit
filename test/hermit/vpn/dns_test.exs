defmodule Hermit.Vpn.DnsTest do
  use ExUnit.Case, async: false

  setup do
    # Clear ETS logs before each test to prevent cross-test state leak
    if :ets.info(:dns_query_logs) != :undefined do
      :ets.match_delete(:dns_query_logs, {:_, :_})
    end
    if :ets.info(:dns_hourly_metrics) != :undefined do
      :ets.match_delete(:dns_hourly_metrics, {:_, :_})
    end
    :ok
  end

  test "Telemetry handler captures event, writes to ETS and broadcasts over PubSub" do
    profile_id = 999
    config_id = 999
    topic = "dns_logs:#{profile_id}"
    Phoenix.PubSub.subscribe(Hermit.PubSub, topic)

    # 1. Trigger telemetry query event
    :telemetry.execute(
      [:hermit, :dns, :query],
      %{duration: 25},
      %{
        profile_id: profile_id,
        config_id: config_id,
        client_ip: {127, 0, 0, 1},
        domain: "google.com",
        qtype: :A,
        status: "resolved",
        answer: "142.250.190.46",
        resolver: "Test",
        enable_query_logging: true
      }
    )
 
    # Force flush batch buffer
    send(Hermit.Dns.Telemetry, :flush_logs)

    # Assert PubSub broadcast
    assert_receive {:dns_log, received_log}, 1000
    assert received_log["pair_id"] == to_string(profile_id)
    assert received_log["domain"] == "google.com"
    assert received_log["status"] == "resolved"
    assert received_log["client_ip"] == "127.0.0.1"

    # Wait for ETS insert
    Process.sleep(100)

    # Assert it was cached in ETS :dns_query_logs
    pattern = {{to_string(profile_id), :_}, :"$1"}
    cached = :ets.select(:dns_query_logs, [{pattern, [], [:"$1"]}])
    assert length(cached) == 1
    assert hd(cached)["domain"] == "google.com"
  end

  test "Telemetry handler enriches logs with client_name from DnsDeviceResolver" do
    profile_id = 888
    config_id = 888
    topic = "dns_logs:#{profile_id}"
    Phoenix.PubSub.subscribe(Hermit.PubSub, topic)
 
    # Trigger cache update manually since resolve_device is a pure cache lookup now
    GenServer.cast(Hermit.Vpn.DnsDeviceResolver, {:trigger_update, profile_id})
    Process.sleep(150)

    # 1. Trigger with mock IP {127, 0, 0, 1} first time (triggers cache update in DnsDeviceResolver)
    :telemetry.execute(
      [:hermit, :dns, :query],
      %{duration: 15},
      %{
        profile_id: profile_id,
        config_id: config_id,
        client_ip: {127, 0, 0, 1},
        domain: "github.com",
        qtype: :A,
        status: "resolved",
        answer: "140.82.121.4",
        resolver: "Test",
        enable_query_logging: true
      }
    )
    send(Hermit.Dns.Telemetry, :flush_logs)

    assert_receive {:dns_log, received_log1}, 1000
    assert received_log1["client_ip"] == "127.0.0.1"

    # Wait briefly for DnsDeviceResolver to populate cache asynchronously
    Process.sleep(100)

    # Trigger second time -> should resolve to "localhost" from cache
    :telemetry.execute(
      [:hermit, :dns, :query],
      %{duration: 15},
      %{
        profile_id: profile_id,
        config_id: config_id,
        client_ip: {127, 0, 0, 1},
        domain: "github.com",
        qtype: :A,
        status: "resolved",
        answer: "140.82.121.4",
        resolver: "Test",
        enable_query_logging: true
      }
    )
    send(Hermit.Dns.Telemetry, :flush_logs)

    assert_receive {:dns_log, received_log1_cached}, 1000
    assert received_log1_cached["client_name"] == "localhost"

    # 2. Trigger with mock-client IP "100.64.0.5" first time (triggers cache update)
    :telemetry.execute(
      [:hermit, :dns, :query],
      %{duration: 25},
      %{
        profile_id: profile_id,
        config_id: config_id,
        client_ip: "100.64.0.5",
        domain: "google.com",
        qtype: :A,
        status: "resolved",
        answer: "142.250.190.46",
        resolver: "Test",
        enable_query_logging: true
      }
    )
    send(Hermit.Dns.Telemetry, :flush_logs)

    assert_receive {:dns_log, received_log2}, 1000
    assert received_log2["client_ip"] == "100.64.0.5"

    # Wait briefly for cache update
    Process.sleep(100)

    # Trigger again to use cached device name
    :telemetry.execute(
      [:hermit, :dns, :query],
      %{duration: 25},
      %{
        profile_id: profile_id,
        config_id: config_id,
        client_ip: "100.64.0.5",
        domain: "google.com",
        qtype: :A,
        status: "resolved",
        answer: "142.250.190.46",
        resolver: "Test",
        enable_query_logging: true
      }
    )
    send(Hermit.Dns.Telemetry, :flush_logs)

    assert_receive {:dns_log, received_log2_cached}, 1000
    assert received_log2_cached["client_name"] == "mock-client"
  end
end
