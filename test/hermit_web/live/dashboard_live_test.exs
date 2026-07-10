defmodule HermitWeb.DashboardLiveTest do
  use HermitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Hermit.Vpn.PairWorker

  setup do
    # Temporarily override config to avoid real docker calls
    original_config = Application.get_env(:hermit, :docker)

    Application.put_env(
      :hermit,
      :docker,
      original_config
      |> Keyword.put(:mock_error, :daemon_unresponsive)
    )

    on_exit(fn ->
      Application.put_env(:hermit, :docker, original_config)
      # Clean up any created pair processes directly without DB calls
      Registry.select(Hermit.Vpn.Registry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
      |> Enum.each(fn id ->
        case Registry.lookup(Hermit.Vpn.Registry, id) do
          [{pid, _}] ->
            DynamicSupervisor.terminate_child(Hermit.Vpn.DynamicSupervisor, pid)

          [] ->
            :ok
        end
      end)
    end)

    :ok
  end

  test "renders dashboard, validates input, and deploys a pair", %{conn: conn} do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "test_inbound_ts",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-12345"}
      })

    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "test_outbound_wg",
        type: "wireguard",
        config: %{"wg_config" => "[Interface]\nPrivateKey = test_key\n"}
      })

    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Active VPN Tunnels"

    # Open Modal
    view |> element("button[phx-click=open_create_modal]") |> render_click()

    # 1. Test validation error
    invalid_form = %{
      "form" => %{
        "pair_id" => "invalid Name Here",
        "inbound_profile_id" => "",
        "outbound_profile_id" => ""
      }
    }

    html =
      view
      |> form("form[phx-submit=save]", invalid_form)
      |> render_change()

    assert html =~ "must contain only lowercase letters, numbers, and underscores"
    assert html =~ "can&#39;t be blank"

    # 2. Test successful deployment trigger
    valid_form = %{
      "form" => %{
        "pair_id" => "prod_us",
        "inbound_profile_id" => inbound_profile.id,
        "outbound_profile_id" => outbound_profile.id
      }
    }

    view
    |> form("form[phx-submit=save]", valid_form)
    |> render_submit()

    # Sleep a moment to let the worker start and broadcast its initial state
    Process.sleep(150)

    html = render(view)
    assert html =~ "VPN Pair &#39;prod_us&#39; started bootstrapping."
    assert html =~ "prod_us"
    assert html =~ "Error"
    assert html =~ "daemon_unresponsive"
  end

  test "real-time updates via PubSub stream to the UI", %{conn: conn} do
    # Start a pair worker manually
    args = %{
      id: "prod_eu",
      wg_config: "[Interface]\nPrivateKey = wgpkey\n",
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
      status: "running",
      wg_status: "starting",
      ts_status: "starting"
    }

    _ = Hermit.Repo.insert!(vpn_pair, on_conflict: :replace_all, conflict_target: :pair_id)

    {:ok, pid} = PairWorker.start_link(args)
    Process.sleep(100)

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "prod_eu"

    # Simulates status changing to :running
    # Fetch current worker state and modify it
    state = GenServer.call(pid, :get_state)

    running_state = %{
      state
      | status: :running,
        wg_status: :running,
        ts_status: :running,
        started_at: System.monotonic_time(:second),
        metrics: %{bytes_received: 1024, bytes_sent: 2048}
    }

    # Broadcast status change
    Phoenix.PubSub.broadcast(Hermit.PubSub, "vpn_pairs", {:vpn_pair_updated, running_state})
    Process.sleep(100)

    html = render(view)
    assert html =~ "Running"
    assert html =~ "1.0 KiB"
    assert html =~ "2.0 KiB"

    # Simulate deletion
    GenServer.stop(pid)
    Process.sleep(100)

    html = render(view)
    refute html =~ "prod_eu"
  end

  test "cannot deploy a pair if the outbound profile is already in use by an active tunnel", %{
    conn: conn
  } do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "inbound_profile",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-1"}
      })

    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "outbound_profile",
        type: "wireguard",
        config: %{"wg_config" => "[Interface]\nPrivateKey = k1\n"}
      })

    # Create an active tunnel (pair_id: active_t) using outbound_profile
    active_pair = %Hermit.Vpn.VpnPair{
      pair_id: "active_t",
      inbound_profile_id: inbound_profile.id,
      outbound_profile_id: outbound_profile.id,
      status: "running",
      wg_status: "running",
      ts_status: "running"
    }

    _ = Hermit.Repo.insert!(active_pair)

    {:ok, view, _html} = live(conn, ~p"/")

    # Open Modal
    view |> element("button[phx-click=open_create_modal]") |> render_click()

    # Try to deploy a new pair (pair_id: new_t) using the same outbound_profile
    form_data = %{
      "form" => %{
        "pair_id" => "new_t",
        "inbound_profile_id" => inbound_profile.id,
        "outbound_profile_id" => outbound_profile.id
      }
    }

    html =
      view
      |> form("form[phx-submit=save]", form_data)
      |> render_submit()

    assert html =~
             "Cannot start VPN Pair: Outbound profile is already in use by active tunnel &#39;active_t&#39;."
  end

  test "performs start, stop, and restart tunnel actions via dashboard icon buttons", %{
    conn: conn
  } do
    args = %{
      id: "action_test",
      wg_config: "[Interface]\nPrivateKey = wgpkey\n",
      ts_auth_key: "tskey-12345"
    }

    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "test_inbound_ts3",
        type: "tailscale",
        config: %{"ts_auth_key" => args.ts_auth_key}
      })

    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "test_outbound_wg3",
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

    _ = Hermit.Repo.insert!(vpn_pair)

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "action_test"

    # Since it is stopped, it should have the "Start Tunnel" button
    html =
      view
      |> element("button[phx-click=start_tunnel][phx-value-id=action_test]")
      |> render_click()

    assert html =~ "Tunnel &#39;action_test&#39; starting..."

    # Simulates status changing to :running
    pid = GenServer.whereis({:via, Registry, {Hermit.Vpn.Registry, "action_test"}})
    assert is_pid(pid)
    state = GenServer.call(pid, :get_state)

    running_state = %{
      state
      | status: :running,
        wg_status: :running,
        ts_status: :running
    }

    Phoenix.PubSub.broadcast(Hermit.PubSub, "vpn_pairs", {:vpn_pair_updated, running_state})
    Process.sleep(100)

    # Re-render view to verify state updated and "Stop Tunnel" & "Restart Tunnel" buttons are visible
    html = render(view)
    assert html =~ "Stop Tunnel"
    assert html =~ "Restart Tunnel"

    # Click Restart Tunnel
    html =
      view
      |> element("button[phx-click=restart_tunnel][phx-value-id=action_test]")
      |> render_click()

    assert html =~ "Tunnel &#39;action_test&#39; restarting..."

    # Click Stop Tunnel
    html =
      view |> element("button[phx-click=stop_tunnel][phx-value-id=action_test]") |> render_click()

    assert html =~ "Tunnel &#39;action_test&#39; stopped."
  end
end
