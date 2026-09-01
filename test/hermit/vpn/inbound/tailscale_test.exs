defmodule Hermit.Vpn.Inbound.TailscaleTest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.Inbound.Tailscale

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

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

      # 3. autoApprovers (App Connector tags should not auto-approve 0.0.0.0/0 subnet routes)
      assert updated["autoApprovers"]["routes"]["0.0.0.0/0"] == []
      assert updated["autoApprovers"]["routes"]["::/0"] == []

      # 4. grants
      assert [grant] = updated["grants"]
      assert grant["src"] == ["*"]
      assert grant["dst"] == [tag]
      assert grant["ip"] == ["*"]
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

    test "removes duplicate domains from other connectors" do
      acl_map = %{
        "nodeAttrs" => [
          %{
            "target" => ["*"],
            "app" => %{
              "tailscale.com/app-connectors" => [
                %{
                  "name" => "hermit-connector-other",
                  "connectors" => ["tag:connector-other"],
                  "domains" => ["duplicate.com", "keep-this.com"]
                },
                %{
                  "name" => "hermit-connector-current",
                  "connectors" => ["tag:connector-current"],
                  "domains" => ["old.com"]
                }
              ]
            }
          }
        ]
      }

      tag = "tag:connector-current"
      domains = ["duplicate.com", "new.com"]

      updated = Tailscale.update_acl_for_app_connector(acl_map, tag, domains)
      [attr] = updated["nodeAttrs"]
      connectors = attr["app"]["tailscale.com/app-connectors"]

      # Find current connector
      current_conn = Enum.find(connectors, &("tag:connector-current" in &1["connectors"]))
      assert current_conn["domains"] == ["duplicate.com", "new.com"]

      # Find other connector
      other_conn = Enum.find(connectors, &("tag:connector-other" in &1["connectors"]))
      assert other_conn["domains"] == ["keep-this.com"]
    end

    test "cleans up and removes app connector configurations when domains is empty" do
      acl_map = %{
        "tagOwners" => %{
          "tag:connector-to-delete" => ["autogroup:admin"],
          "tag:keep-me" => ["autogroup:admin"]
        },
        "nodeAttrs" => [
          %{
            "target" => ["*"],
            "app" => %{
              "tailscale.com/app-connectors" => [
                %{
                  "name" => "hermit-connector-to-delete",
                  "connectors" => ["tag:connector-to-delete"],
                  "domains" => ["delete.com"]
                },
                %{
                  "name" => "hermit-connector-keep",
                  "connectors" => ["tag:keep-me"],
                  "domains" => ["keep.com"]
                }
              ]
            }
          }
        ],
        "autoApprovers" => %{
          "routes" => %{
            "0.0.0.0/0" => ["tag:connector-to-delete", "tag:keep-me"],
            "::/0" => ["tag:connector-to-delete", "tag:keep-me"]
          }
        },
        "grants" => [
          %{
            "src" => ["autogroup:member"],
            "dst" => ["tag:connector-to-delete"],
            "ip" => ["tcp:53", "udp:53"]
          },
          %{
            "src" => ["autogroup:member"],
            "dst" => ["tag:keep-me"],
            "ip" => ["tcp:53", "udp:53"]
          }
        ]
      }

      tag = "tag:connector-to-delete"
      updated = Tailscale.update_acl_for_app_connector(acl_map, tag, [])

      # 1. tagOwners should not have the deleted tag
      refute Map.has_key?(updated["tagOwners"], tag)
      assert Map.has_key?(updated["tagOwners"], "tag:keep-me")

      # 2. nodeAttrs should not have the deleted connector
      [attr] = updated["nodeAttrs"]
      connectors = attr["app"]["tailscale.com/app-connectors"]
      refute Enum.any?(connectors, &("tag:connector-to-delete" in &1["connectors"]))
      assert Enum.any?(connectors, &("tag:keep-me" in &1["connectors"]))

      # 3. autoApprovers routes should not have the deleted tag
      refute tag in updated["autoApprovers"]["routes"]["0.0.0.0/0"]
      refute tag in updated["autoApprovers"]["routes"]["::/0"]
      assert "tag:keep-me" in updated["autoApprovers"]["routes"]["0.0.0.0/0"]
      assert "tag:keep-me" in updated["autoApprovers"]["routes"]["::/0"]

      # 4. grants should not have the deleted grant
      refute Enum.any?(updated["grants"], &(tag in &1["dst"]))
      assert Enum.any?(updated["grants"], &("tag:keep-me" in &1["dst"]))
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

  describe "resolve_port/2" do
    test "returns explicit ts_port when configured" do
      config = %{"ts_port" => "41655"}
      assert Tailscale.resolve_port("pair1", config) == 41655

      config_int = %{"ts_port" => 41660}
      assert Tailscale.resolve_port("pair1", config_int) == 41660
    end

    test "allocates port within custom ts_port_range" do
      config = %{"ts_port_range" => "42000-42010"}
      port = Tailscale.resolve_port("pair_abc", config)
      assert port >= 42000 and port <= 42010
    end

    test "allocates port within default range 41642-41700 when config is empty" do
      port = Tailscale.resolve_port("pair_xyz", %{})
      assert port >= 41642 and port <= 41700
    end
  end

  describe "append_advertise_args/3" do
    # Non-existent socket -> get_current_tags/2 safely returns [].
    @opts %{
      pair_id: "test_pair",
      wg_name: "hermit_wg_test_pair",
      socket_path: "/run/tailscaled.nonexistent.socket",
      advertise_exit_node: false,
      advertise_connector: false
    }

    test "advertises custom subnet routes from config (bootstrap parity)" do
      config = %{"advertise_routes" => "192.168.1.0/24, 10.0.0.0/8"}

      args = Tailscale.append_advertise_args(["up", "--reset"], config, @opts)

      assert "--advertise-routes=192.168.1.0/24,10.0.0.0/8" in args
    end

    test "emits empty advertise-routes when no routes configured" do
      args = Tailscale.append_advertise_args(["up", "--reset"], %{}, @opts)

      assert "--advertise-routes=" in args
    end

    test "toggles advertise-exit-node from the flag" do
      on =
        Tailscale.append_advertise_args(
          ["up"],
          %{},
          Map.put(@opts, :advertise_exit_node, true)
        )

      assert "--advertise-exit-node" in on

      off =
        Tailscale.append_advertise_args(
          ["up"],
          %{},
          Map.put(@opts, :advertise_exit_node, false)
        )

      assert "--advertise-exit-node=false" in off
    end

    test "advertises app connector tag when enabled" do
      args =
        Tailscale.append_advertise_args(
          ["up"],
          %{},
          Map.put(@opts, :advertise_connector, true)
        )

      assert "--advertise-connector" in args
      assert Enum.any?(args, &String.starts_with?(&1, "--advertise-tags="))
    end
  end
end
