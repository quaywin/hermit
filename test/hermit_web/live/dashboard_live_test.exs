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

  test "renders edit inbound profile modal, validates, and saves updates", %{conn: conn} do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "inbound_to_edit",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-old"}
      })

    {:ok, view, _html} = live(conn, ~p"/")

    # Switch to inbound tab
    view
    |> element("button[phx-click=set_tab][phx-value-tab=inbound]")
    |> render_click()

    # Click edit button
    html =
      view
      |> element("#edit-inbound-#{inbound_profile.id}")
      |> render_click()

    assert html =~ "Edit Inbound Profile"
    assert html =~ "inbound_to_edit"

    # Test validation error
    # First, change type to proxy to render the port input field
    view
    |> form("#edit-inbound-profile-form", %{
      "inbound_profile" => %{"type" => "proxy"}
    })
    |> render_change()

    invalid_form = %{
      "inbound_profile" => %{
        "name" => "",
        "type" => "proxy",
        "config" => %{"port" => "abc"}
      }
    }

    html =
      view
      |> form("#edit-inbound-profile-form", invalid_form)
      |> render_change()

    assert html =~ "can&#39;t be blank"
    assert html =~ "Proxy port must be a valid number between 1 and 65535"

    # Test successful update
    # First, change type back to tailscale so the tailscale fields are rendered in the DOM
    view
    |> form("#edit-inbound-profile-form", %{
      "inbound_profile" => %{"type" => "tailscale"}
    })
    |> render_change()

    valid_form = %{
      "inbound_profile" => %{
        "name" => "inbound_updated",
        "type" => "tailscale",
        "config" => %{"ts_auth_key" => "tskey-new"}
      }
    }

    html =
      view
      |> form("#edit-inbound-profile-form", valid_form)
      |> render_submit()

    assert html =~ "Inbound Profile updated successfully"
    refute html =~ "Edit Inbound Profile"
    assert html =~ "inbound_updated"

    # Verify update in DB
    updated = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, inbound_profile.id)
    assert updated.name == "inbound_updated"
    assert updated.config["ts_auth_key"] == "tskey-new"
  end

  test "renders edit outbound profile modal, validates, and saves updates", %{conn: conn} do
    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "outbound_to_edit",
        type: "wireguard",
        config: %{"wg_config" => "[Interface]\nPrivateKey = oldkey\n"}
      })

    {:ok, view, _html} = live(conn, ~p"/")

    # Switch to outbound tab
    view
    |> element("button[phx-click=set_tab][phx-value-tab=outbound]")
    |> render_click()

    # Click edit button
    html =
      view
      |> element("#edit-outbound-#{outbound_profile.id}")
      |> render_click()

    assert html =~ "Edit Outbound Profile"
    assert html =~ "outbound_to_edit"

    # Test validation error
    invalid_form = %{
      "outbound_profile" => %{
        "name" => "",
        "type" => "wireguard",
        "config" => %{"wg_config" => ""}
      }
    }

    html =
      view
      |> form("#edit-outbound-profile-form", invalid_form)
      |> render_change()

    assert html =~ "can&#39;t be blank"
    assert html =~ "WireGuard requires wg_config payload"

    # Test successful update
    valid_form = %{
      "outbound_profile" => %{
        "name" => "outbound_updated",
        "type" => "wireguard",
        "config" => %{"wg_config" => "[Interface]\nPrivateKey = newkey\n"}
      }
    }

    html =
      view
      |> form("#edit-outbound-profile-form", valid_form)
      |> render_submit()

    assert html =~ "Outbound Profile updated successfully"
    refute html =~ "Edit Outbound Profile"
    assert html =~ "outbound_updated"

    # Verify update in DB
    updated = Hermit.Repo.get!(Hermit.Vpn.OutboundProfile, outbound_profile.id)
    assert updated.name == "outbound_updated"
    assert updated.config["wg_config"] == "[Interface]\nPrivateKey = newkey\n"
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
end
