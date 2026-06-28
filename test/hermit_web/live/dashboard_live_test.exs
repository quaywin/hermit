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
      |> Keyword.put(:socket_path, "/invalid/docker.sock")
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

    assert html =~ "HERMIT GATEWAY"

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

  test "switches tabs using CSS hidden class to preserve stream state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # By default, tunnels tab is active, inbound/outbound are hidden
    assert render(view) =~ "Deploy VPN Tunnel"
    assert has_element?(view, "div.hidden", "Create Inbound Profile")
    assert has_element?(view, "div.hidden", "Create Outbound Profile")
    refute has_element?(view, "div.hidden", "Deploy VPN Tunnel")

    # Switch to inbound tab
    view
    |> element("button[phx-click=set_tab][phx-value-tab=inbound]")
    |> render_click()

    # Now inbound is visible, tunnels and outbound are hidden
    assert has_element?(view, "div.hidden", "Deploy VPN Tunnel")
    refute has_element?(view, "div.hidden", "Create Inbound Profile")
    assert has_element?(view, "div.hidden", "Create Outbound Profile")

    # Switch to outbound tab
    view
    |> element("button[phx-click=set_tab][phx-value-tab=outbound]")
    |> render_click()

    assert has_element?(view, "div.hidden", "Deploy VPN Tunnel")
    assert has_element?(view, "div.hidden", "Create Inbound Profile")
    refute has_element?(view, "div.hidden", "Create Outbound Profile")
  end
end
