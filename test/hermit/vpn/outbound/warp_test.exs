defmodule Hermit.Vpn.Outbound.WarpTest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.Outbound.Warp
  alias Hermit.Vpn.Outbound.WarpBridge
  alias Hermit.Vpn.OutboundProfile

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

  describe "validate_nat64_prefix/1" do
    test "accepts valid /96 prefixes with or without suffix and normalizes them" do
      assert {:ok, "2602:fc59:b0:64::/96"} = Warp.validate_nat64_prefix("2602:fc59:b0:64::/96")
      assert {:ok, "2602:fc59:b0:64::/96"} = Warp.validate_nat64_prefix("  2602:fc59:b0:64::  ")

      assert {:ok, "2a00:1098:2b::1:0:0/96"} =
               Warp.validate_nat64_prefix("2a00:1098:2b::1:0:0/96")
    end

    test "rejects invalid prefixes, non-/96 lengths, and non-zero host bits" do
      assert {:error, _} = Warp.validate_nat64_prefix(nil)
      assert {:error, _} = Warp.validate_nat64_prefix("")
      assert {:error, _} = Warp.validate_nat64_prefix("2602:fc59:b0:64::/64")
      assert {:error, _} = Warp.validate_nat64_prefix("2602:fc59:b0:64::1/96")
      assert {:error, _} = Warp.validate_nat64_prefix("not-an-ipv6")
    end
  end

  describe "synthesize_nat64_endpoint/3" do
    test "synthesizes verified RFC 6052 endpoints for curated regions" do
      assert {:ok, "[2602:fc59:b0:64::a29f:c001]:2408"} =
               Warp.synthesize_nat64_endpoint("2602:fc59:b0:64::/96")

      assert {:ok, "[2a00:1098:2b::1:a29f:c001]:2408"} =
               Warp.synthesize_nat64_endpoint("2a00:1098:2b::1:0:0/96")

      assert {:ok, "[2a01:4f9:c010:3f02:64:0:a29f:c001]:2408"} =
               Warp.synthesize_nat64_endpoint("2a01:4f9:c010:3f02:64::/96")
    end
  end

  describe "generate_keypair/0 and build_wg_config/3" do
    test "generates valid 32-byte base64 keys and formats wg0.conf" do
      {priv, pub} = Warp.generate_keypair()
      assert byte_size(Base.decode64!(priv)) == 32
      assert byte_size(Base.decode64!(pub)) == 32
      assert priv != pub

      conf =
        Warp.build_wg_config(
          %{
            "private_key" => priv,
            "v4" => "172.16.0.2",
            "v6" => "2606:4700:110::2",
            "peer_public_key" => "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
          },
          "[2602:fc59:b0:64::a29f:c001]:2408",
          "1280"
        )

      assert conf =~ "PrivateKey = #{priv}"
      assert conf =~ "Address = 172.16.0.2/32, 2606:4700:110::2/128"
      assert conf =~ "MTU = 1280"
      assert conf =~ "Endpoint = [2602:fc59:b0:64::a29f:c001]:2408"
      assert conf =~ "PersistentKeepalive = 25"
    end
  end

  describe "ensure_account/2" do
    test "registers via HTTP client, persists warp_account.json, and reuses cached account" do
      storage_dir =
        Path.expand("storage/test_warp_reg_#{System.unique_integer([:positive])}", File.cwd!())

      File.mkdir_p!(storage_dir)
      on_exit(fn -> File.rm_rf!(storage_dir) end)

      test_pid = self()

      post_fn = fn url, opts ->
        send(test_pid, {:post_called, url, opts[:json]})

        {:ok,
         %{
           status: 200,
           body: %{
             "id" => "cf-device-123",
             "token" => "cf-token-abc",
             "config" => %{
               "interface" => %{
                 "addresses" => %{
                   "v4" => "172.16.0.2",
                   "v6" => "2606:4700:110:8000::55"
                 }
               },
               "peers" => [
                 %{"public_key" => "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="}
               ]
             }
           }
         }}
      end

      patch_fn = fn url, opts ->
        send(test_pid, {:patch_called, url, opts[:json]})
        {:ok, %{status: 200, body: %{"warp_enabled" => true}}}
      end

      assert {:ok, account1} =
               Warp.ensure_account(storage_dir, post_fn: post_fn, patch_fn: patch_fn)

      assert_received {:post_called, "https://api.cloudflareclient.com/v0a2158/reg", payload}
      assert is_binary(payload["key"]) and payload["key"] != ""

      assert_received {:patch_called,
                       "https://api.cloudflareclient.com/v0a2158/reg/cf-device-123",
                       %{"warp_enabled" => true}}

      assert File.exists?(Path.join(storage_dir, "warp_account.json"))

      assert {:ok, account2} =
               Warp.ensure_account(storage_dir, post_fn: post_fn, patch_fn: patch_fn)

      assert account1 == account2
      refute_received {:post_called, _, _}
    end
  end

  describe "OutboundProfile changeset validation for warp" do
    test "validates preset regions and custom NAT64 prefixes" do
      for region <- ["auto", "us_fremont", "us_illinois", "nl_amsterdam", "fi_helsinki"] do
        cs =
          OutboundProfile.changeset(%OutboundProfile{}, %{
            name: "WARP #{region}",
            type: "warp",
            config: %{"region" => region}
          })

        assert cs.valid?, "expected region #{region} to be valid"
      end

      valid_custom =
        OutboundProfile.changeset(%OutboundProfile{}, %{
          name: "WARP Custom",
          type: "warp",
          config: %{"region" => "custom", "custom_nat64_prefix" => "2602:fc59:b0:64::/96"}
        })

      assert valid_custom.valid?

      invalid_region =
        OutboundProfile.changeset(%OutboundProfile{}, %{
          name: "WARP Bad Region",
          type: "warp",
          config: %{"region" => "mars"}
        })

      refute invalid_region.valid?

      missing_custom =
        OutboundProfile.changeset(%OutboundProfile{}, %{
          name: "WARP Missing Custom",
          type: "warp",
          config: %{"region" => "custom", "custom_nat64_prefix" => ""}
        })

      refute missing_custom.valid?

      bad_custom =
        OutboundProfile.changeset(%OutboundProfile{}, %{
          name: "WARP Bad Custom",
          type: "warp",
          config: %{"region" => "custom", "custom_nat64_prefix" => "2602:fc59:b0:64::/64"}
        })

      refute bad_custom.valid?
    end
  end

  describe "bootstrap, lifecycle, and WarpBridge ref-counting in mock mode" do
    test "auto region skips bridge and writes MTU 1380 config; NAT64 regions ref-count bridge" do
      pair_auto = "test_warp_auto_#{System.unique_integer([:positive])}"
      pair_us = "test_warp_us_#{System.unique_integer([:positive])}"
      pair_nl = "test_warp_nl_#{System.unique_integer([:positive])}"

      dir_auto = Path.expand("storage/#{pair_auto}", File.cwd!())
      dir_us = Path.expand("storage/#{pair_us}", File.cwd!())
      dir_nl = Path.expand("storage/#{pair_nl}", File.cwd!())

      on_exit(fn ->
        Warp.cleanup(pair_auto, dir_auto)
        Warp.cleanup(pair_us, dir_us)
        Warp.cleanup(pair_nl, dir_nl)
        File.rm_rf!(dir_auto)
        File.rm_rf!(dir_us)
        File.rm_rf!(dir_nl)
      end)

      assert {:ok, "wg0"} = Warp.bootstrap(pair_auto, dir_auto, %{"region" => "auto"})
      auto_conf = File.read!(Path.join(dir_auto, "wg0.conf"))
      assert auto_conf =~ "MTU = 1380"
      assert auto_conf =~ "Endpoint = 162.159.192.1:2408"
      refute MapSet.member?(WarpBridge.active_pairs(), pair_auto)

      assert {:ok, "wg0"} = Warp.bootstrap(pair_us, dir_us, %{"region" => "us_fremont"})
      us_conf = File.read!(Path.join(dir_us, "wg0.conf"))
      assert us_conf =~ "MTU = 1280"
      assert us_conf =~ "Endpoint = [2602:fc59:b0:64::a29f:c001]:2408"
      assert MapSet.member?(WarpBridge.active_pairs(), pair_us)

      assert {:ok, "wg0"} = Warp.bootstrap(pair_nl, dir_nl, %{"region" => "nl_amsterdam"})
      nl_conf = File.read!(Path.join(dir_nl, "wg0.conf"))
      assert nl_conf =~ "MTU = 1280"
      assert nl_conf =~ "Endpoint = [2a00:1098:2b::1:a29f:c001]:2408"
      assert MapSet.member?(WarpBridge.active_pairs(), pair_us)
      assert MapSet.member?(WarpBridge.active_pairs(), pair_nl)

      assert :running = Warp.get_status(pair_us, dir_us)
      assert {:ok, %{bytes_received: 1024, bytes_sent: 2048}} = Warp.get_metrics(pair_us, dir_us)

      # Releasing one NAT64 pair keeps the other active on the bridge
      assert :ok = Warp.cleanup(pair_us, dir_us)
      refute MapSet.member?(WarpBridge.active_pairs(), pair_us)
      assert MapSet.member?(WarpBridge.active_pairs(), pair_nl)

      # Releasing the last NAT64 pair clears the bridge
      assert :ok = Warp.cleanup(pair_nl, dir_nl)
      refute MapSet.member?(WarpBridge.active_pairs(), pair_nl)
    end
  end
end
