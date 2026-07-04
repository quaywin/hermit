defmodule Hermit.Vpn.Inbound.TailscaleTest do
  use ExUnit.Case, async: true
  alias Hermit.Vpn.Inbound.Tailscale

  describe "clean_hujson/1" do
    test "removes line comments" do
      hujson = """
      // This is a comment
      {
        "a": 1 # another comment
      }
      """

      assert {:ok, parsed} = Jason.decode(Tailscale.clean_hujson(hujson))
      assert parsed == %{"a" => 1}
    end

    test "removes block comments" do
      hujson = """
      {
        /* block comment
           on multiple lines */
        "a": 1
      }
      """

      assert {:ok, parsed} = Jason.decode(Tailscale.clean_hujson(hujson))
      assert parsed == %{"a" => 1}
    end

    test "does not strip comment markers inside strings" do
      hujson = """
      {
        "url": "https://api.tailscale.com",
        "comment": "This has a # inside the string",
        "nested": "/* block comment inside string */"
      }
      """

      assert {:ok, parsed} = Jason.decode(Tailscale.clean_hujson(hujson))
      assert parsed["url"] == "https://api.tailscale.com"
      assert parsed["comment"] == "This has a # inside the string"
      assert parsed["nested"] == "/* block comment inside string */"
    end

    test "removes trailing commas" do
      hujson = """
      {
        "a": [1, 2, 3,],
        "b": {"nested": "value",},
      }
      """

      assert {:ok, parsed} = Jason.decode(Tailscale.clean_hujson(hujson))
      assert parsed == %{"a" => [1, 2, 3], "b" => %{"nested" => "value"}}
    end

    test "handles escaped quotes correctly" do
      hujson = """
      {
        "message": "Hello \\"world\\"!"
      }
      """

      assert {:ok, parsed} = Jason.decode(Tailscale.clean_hujson(hujson))
      assert parsed["message"] == "Hello \"world\"!"
    end
  end

  describe "update_acl_for_app_connector/3" do
    test "adds app connector configuration to an empty ACL map" do
      acl_map = %{}
      tag = "tag:connector"
      domains = ["example.com", "*.example.com"]

      updated = Tailscale.update_acl_for_app_connector(acl_map, tag, domains)

      # 1. tagOwners
      assert updated["tagOwners"][tag] == ["autogroup:admin"]

      # 2. nodeAttrs
      assert [attr] = updated["nodeAttrs"]
      assert attr["target"] == ["*"]
      assert [conn] = attr["app"]["tailscale.com/app-connectors"]
      assert conn["name"] == "hermit-connector-connector"
      assert conn["connectors"] == [tag]
      assert conn["domains"] == domains

      # 3. autoApprovers
      assert updated["autoApprovers"]["routes"]["0.0.0.0/0"] == [tag]
      assert updated["autoApprovers"]["routes"]["::/0"] == [tag]

      # 4. grants
      assert [grant] = updated["grants"]
      assert grant["src"] == ["autogroup:member"]
      assert grant["dst"] == [tag]
      assert grant["ip"] == ["tcp:53", "udp:53"]
    end

    test "updates domains for an existing app connector tag in nodeAttrs" do
      acl_map = %{
        "nodeAttrs" => [
          %{
            "target" => ["*"],
            "app" => %{
              "tailscale.com/app-connectors" => [
                %{
                  "name" => "hermit-connector-connector",
                  "connectors" => ["tag:connector"],
                  "domains" => ["old.com"]
                }
              ]
            }
          }
        ]
      }

      tag = "tag:connector"
      domains = ["new.com", "other.com"]

      updated = Tailscale.update_acl_for_app_connector(acl_map, tag, domains)
      [attr] = updated["nodeAttrs"]
      [conn] = attr["app"]["tailscale.com/app-connectors"]
      assert conn["domains"] == domains
    end
  end

  describe "update_dns_settings_local/3" do
    test "returns updated on mock mode" do
      assert {:ok, :updated} =
               Tailscale.update_dns_settings_local("test_pair", "custom", "76.76.2.0, 76.76.10.0")
    end
  end

  describe "approve_exit_node/1" do
    test "returns approved on mock mode" do
      assert {:ok, :approved} = Tailscale.approve_exit_node("test_pair")
    end
  end
end
