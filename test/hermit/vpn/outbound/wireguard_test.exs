defmodule Hermit.Vpn.Outbound.WireGuardTest do
  use ExUnit.Case, async: true
  alias Hermit.Vpn.Outbound.WireGuard

  describe "parse_addresses/1" do
    test "parses single IPv4 address" do
      config = """
      [Interface]
      PrivateKey = aaaa
      Address = 10.64.0.2/32
      """

      assert WireGuard.parse_addresses(config) == ["10.64.0.2/32"]
    end

    test "parses dual-stack IPv4 and IPv6 on a single line with space" do
      config = """
      [Interface]
      PrivateKey = aaaa
      Address = 10.64.0.2/32, fc00:bbbb:bbbb:bb01::1:2014/128
      """

      assert WireGuard.parse_addresses(config) == [
               "10.64.0.2/32",
               "fc00:bbbb:bbbb:bb01::1:2014/128"
             ]
    end

    test "parses multiple Address lines" do
      config = """
      [Interface]
      PrivateKey = aaaa
      Address = 10.64.0.2/32
      Address = 2606:4700::1/64
      """

      assert WireGuard.parse_addresses(config) == [
               "10.64.0.2/32",
               "2606:4700::1/64"
             ]
    end

    test "ignores comments on Address line" do
      config = """
      [Interface]
      Address = 10.64.0.2/32, fd00::2/128 # primary and secondary IP
      """

      assert WireGuard.parse_addresses(config) == ["10.64.0.2/32", "fd00::2/128"]
    end
  end

  describe "parse_dns_servers/2" do
    test "parses multiple comma-separated DNS IPs" do
      config = """
      [Interface]
      DNS = 10.64.0.1, 1.1.1.1 # DNS servers
      """

      assert WireGuard.parse_dns_servers(config) == ["10.64.0.1", "1.1.1.1"]
    end

    test "uses Tailscale DNS when configured" do
      config = """
      [Interface]
      DNS = 1.1.1.1
      """

      assert WireGuard.parse_dns_servers(config, %{"use_tailscale_dns" => true}) == [
               "100.100.100.100"
             ]
    end
  end

  describe "parse_mtu/1" do
    test "extracts configured MTU" do
      config = """
      [Interface]
      MTU = 1420
      """

      assert WireGuard.parse_mtu(config) == "1420"
    end

    test "falls back to default 1360 when omitted" do
      config = """
      [Interface]
      PrivateKey = aaaa
      """

      assert WireGuard.parse_mtu(config) == "1360"
    end
  end
end
