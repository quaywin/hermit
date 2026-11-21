defmodule Hermit.Dns.TelemetryTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Hermit.Dns.Telemetry

  describe "get_24h_summary/0" do
    test "returns structured 24h summary map with 24 hours" do
      summary = Telemetry.get_24h_summary()

      assert is_map(summary)
      assert is_integer(summary.total_queries)
      assert is_integer(summary.blocked_queries)
      assert is_integer(summary.block_rate)
      assert length(summary.hourly_series) == 24

      first_point = hd(summary.hourly_series)
      assert Map.has_key?(first_point, :hour_label)
      assert Map.has_key?(first_point, :hour_ts)
      assert Map.has_key?(first_point, :total)
      assert Map.has_key?(first_point, :blocked)
    end
  end

  describe "Hermit.format_number/1" do
    test "formats numbers with commas" do
      assert Hermit.format_number(0) == "0"
      assert Hermit.format_number(999) == "999"
      assert Hermit.format_number(1000) == "1,000"
      assert Hermit.format_number(1_234_567) == "1,234,567"
      assert Hermit.format_number(nil) == "0"
    end
  end

  describe "handler resilience and auto-recovery" do
    test "ensure_attached/0 re-attaches handler if detached" do
      on_exit(fn -> Telemetry.ensure_attached() end)

      :telemetry.detach("hermit-dns-queries")
      handlers = :telemetry.list_handlers([:hermit, :dns, :query])
      refute Enum.any?(handlers, fn h -> h.id == "hermit-dns-queries" end)

      Telemetry.ensure_attached()

      handlers_after = :telemetry.list_handlers([:hermit, :dns, :query])
      assert Enum.any?(handlers_after, fn h -> h.id == "hermit-dns-queries" end)
    end

    test "handle_event does not crash or detach handler on edge-case types" do
      Telemetry.ensure_attached()

      # Send unexpected types that previously triggered FunctionClauseError or detachment
      edge_cases = [
        %{qtype: :DNSKEY, client_ip: {100, 64, 0, 2}},
        %{qtype: 48, client_ip: "100.64.0.3"},
        %{qtype: "A", client_ip: {127, 0, 0, 1}},
        %{qtype: nil, client_ip: nil},
        %{qtype: :unhandled_atom, client_ip: {10, 0, 0, 1}}
      ]

      for meta <- edge_cases do
        metadata =
          Map.merge(
            %{
              profile_id: 1,
              config_id: 1,
              domain: "example.com",
              status: "resolved",
              answer: "1.2.3.4",
              resolver: "Test",
              enable_query_logging: true
            },
            meta
          )

        log =
          capture_log(fn ->
            :telemetry.execute([:hermit, :dns, :query], %{duration: 5}, metadata)
          end)

        refute log =~ "prevented detachment"

        # Verify handler is STILL attached after the query
        handlers = :telemetry.list_handlers([:hermit, :dns, :query])
        assert Enum.any?(handlers, fn h -> h.id == "hermit-dns-queries" end)
      end
    end
  end
end
