defmodule Hermit.Vpn.RoutingParserTest do
  use ExUnit.Case, async: true
  alias Hermit.Vpn.RoutingParser

  describe "parse/1" do
    test "handles nil and empty string" do
      assert RoutingParser.parse(nil) == %{subnets: [], domains: [], raw: ""}
      assert RoutingParser.parse("") == %{subnets: [], domains: [], raw: ""}
      assert RoutingParser.parse("   ") == %{subnets: [], domains: [], raw: "   "}
    end

    test "classifies IPv4 CIDRs and single IPs" do
      input = "192.168.1.0/24, 10.0.0.0/8, 103.56.12.34"
      result = RoutingParser.parse(input)

      assert result.subnets == ["192.168.1.0/24", "10.0.0.0/8", "103.56.12.34/32"]
      assert result.domains == []

      assert RoutingParser.format_subnets(result.subnets) ==
               "192.168.1.0/24,10.0.0.0/8,103.56.12.34/32"
    end

    test "classifies domains and wildcard domains" do
      input = "netflix.com, *.openai.com, chatgpt.com, hulu.com"
      result = RoutingParser.parse(input)

      assert result.subnets == []
      assert result.domains == ["netflix.com", "*.openai.com", "chatgpt.com", "hulu.com"]
    end

    test "classifies mixed input with commas, newlines, spaces" do
      input = """
      netflix.com, 192.168.1.0/24
      *.openai.com 10.10.0.0/16
      103.56.12.34
      bbc.co.uk
      """

      result = RoutingParser.parse(input)

      assert result.subnets == ["192.168.1.0/24", "10.10.0.0/16", "103.56.12.34/32"]
      assert result.domains == ["netflix.com", "*.openai.com", "bbc.co.uk"]
    end

    test "deduplicates and normalizes to lowercase" do
      input = "NETFLIX.COM, netflix.com, 10.0.0.0/8, 10.0.0.0/8"
      result = RoutingParser.parse(input)

      assert result.domains == ["netflix.com"]
      assert result.subnets == ["10.0.0.0/8"]
    end

    test "ignores invalid syntax cleanly" do
      input = "not-a-domain, 999.999.999.999, netflix.com, 10.0.0.1/40"
      result = RoutingParser.parse(input)

      assert result.domains == ["netflix.com"]
      assert result.subnets == []
    end
  end
end
