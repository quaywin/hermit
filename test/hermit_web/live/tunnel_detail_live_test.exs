defmodule HermitWeb.TunnelDetailLiveTest do
  use HermitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    original_config = Application.get_env(:hermit, :docker)

    Application.put_env(
      :hermit,
      :docker,
      original_config
      |> Keyword.put(:socket_path, "/invalid/docker.sock")
      |> Keyword.put(:mock_error, :daemon_unresponsive)
    )

    on_exit(fn ->
      Application.put_env(:hermit, :docker, original_config)

      Registry.select(Hermit.Vpn.Registry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
      |> Enum.each(fn id ->
        case Registry.lookup(Hermit.Vpn.Registry, id) do
          [{pid, _}] ->
            Elixir.DynamicSupervisor.terminate_child(Hermit.Vpn.DynamicSupervisor, pid)

          [] ->
            :ok
        end
      end)
    end)

    :ok
  end

  test "redirects to dashboard when tunnel does not exist", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/tunnels/non_existent")
  end

  test "renders tunnel detail page for existing tunnel and performs actions", %{conn: conn} do
    # Start a pair worker manually
    args = %{
      id: "detail_test",
      wg_config: "[Interface]\nPrivateKey = wgpkey\n",
      ts_auth_key: "tskey-12345"
    }

    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "test_inbound_ts",
        type: "tailscale",
        config: %{"ts_auth_key" => args.ts_auth_key}
      })

    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "test_outbound_wg",
        type: "wireguard",
        config: %{"wg_config" => args.wg_config}
      })

    # Persist the tunnel in Ecto so get_state can find it
    vpn_pair = %Hermit.Vpn.VpnPair{
      pair_id: args.id,
      inbound_profile_id: inbound_profile.id,
      outbound_profile_id: outbound_profile.id,
      status: "stopped",
      wg_status: "stopped",
      ts_status: "stopped"
    }

    _ = Hermit.Repo.insert!(vpn_pair, on_conflict: :replace_all, conflict_target: :pair_id)

    {:ok, view, html} = live(conn, ~p"/tunnels/detail_test")
    assert html =~ "Tunnel Detail: detail_test"
    assert html =~ "Stopped"

    # 1. Trigger start Wireguard
    html = view |> element("button", "Start Wireguard") |> render_click()
    assert html =~ "Starting"

    # Simulate state updates to running
    pid = GenServer.whereis({:via, Registry, {Hermit.Vpn.Registry, "detail_test"}})
    assert is_pid(pid)
    state = GenServer.call(pid, :get_state)

    running_state = %{
      state
      | wg_status: :running,
        ts_status: :running,
        status: :running,
        metrics: Map.put(state.metrics, :wg_port, 51820)
    }

    Phoenix.PubSub.broadcast(Hermit.PubSub, "vpn_pairs", {:vpn_pair_updated, running_state})
    Process.sleep(100)

    html = render(view)
    assert html =~ "Running"
    assert html =~ "Listening Port:"
    assert html =~ "51820"

    # 2. Trigger stop Wireguard
    html = view |> element("button", "Stop Wireguard") |> render_click()
    assert html =~ "Stopped"

    # 3. Trigger delete tunnel
    assert {:error, {:live_redirect, %{to: "/"}}} =
             view |> element("button", "Delete Entire Tunnel") |> render_click()
  end

  test "renders edit config modal, validates, and saves configuration", %{conn: conn} do
    args = %{
      id: "edit_test",
      wg_config:
        "[Interface]\nAddress = 10.0.0.5/24\nPrivateKey = oldpkey\n\n[Peer]\nPublicKey = oldpeerkey\nEndpoint = 127.0.0.1:51820\n",
      ts_auth_key: "tskey-12345"
    }

    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "test_inbound_ts2",
        type: "tailscale",
        config: %{"ts_auth_key" => args.ts_auth_key}
      })

    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "test_outbound_wg2",
        type: "wireguard",
        config: %{"wg_config" => args.wg_config}
      })

    vpn_pair = %Hermit.Vpn.VpnPair{
      pair_id: args.id,
      inbound_profile_id: inbound_profile.id,
      outbound_profile_id: outbound_profile.id,
      status: "stopped",
      wg_status: "stopped",
      ts_status: "stopped"
    }

    _ = Hermit.Repo.insert!(vpn_pair, on_conflict: :replace_all, conflict_target: :pair_id)

    {:ok, view, html} = live(conn, ~p"/tunnels/edit_test")

    # Verify basic config is parsed and displayed, and raw private key is NOT displayed
    assert html =~ "Interface Address:"
    assert html =~ "10.0.0.5/24"
    assert html =~ "Peer Endpoint:"
    assert html =~ "127.0.0.1:51820"
    refute html =~ "oldpkey"
    refute html =~ "oldpeerkey"

    # Verify modal is hidden initially
    refute html =~ "Edit WireGuard Configuration"

    # Click edit button to show modal
    html = view |> element("button#edit-wg-config-btn") |> render_click()
    assert html =~ "Edit WireGuard Configuration"
    assert html =~ "oldpkey"

    # Submit invalid config (empty)
    invalid_form = %{
      "vpn_pair" => %{
        "wg_config" => ""
      }
    }

    html =
      view
      |> form("#edit-wg-form", invalid_form)
      |> render_change()

    assert html =~ "can&#39;t be blank"

    # Submit valid config
    valid_form = %{
      "vpn_pair" => %{
        "wg_config" =>
          "[Interface]\nAddress = 10.0.0.10/24\nPrivateKey = newpkey\n\n[Peer]\nPublicKey = newpeerkey\nEndpoint = 127.0.0.1:51820\n"
      }
    }

    html =
      view
      |> form("#edit-wg-form", valid_form)
      |> render_submit()

    # Verify success flash, modal closed, and details updated on the main card
    assert html =~ "WireGuard configuration updated successfully"
    refute html =~ "Edit WireGuard Configuration"
    assert html =~ "10.0.0.10/24"
    assert html =~ "127.0.0.1:51820"
    refute html =~ "newpkey"
    refute html =~ "newpeerkey"
  end
end
