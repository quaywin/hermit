defmodule Hermit.Dns.TelemetryTest do
  use ExUnit.Case, async: false
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
      assert Hermit.format_number(1234567) == "1,234,567"
      assert Hermit.format_number(nil) == "0"
    end
  end
end
