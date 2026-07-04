defmodule HermitWeb.TunnelDetailLiveTest do
  use HermitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Hermit.Vpn.PairWorker

  setup do
    original_config = Application.get_env(:hermit, :docker)

    Application.put_env(
      :hermit,
      :docker,
      original_config
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

  test "cannot start Wireguard if the outbound profile is already in use by an active tunnel", %{
    conn: conn
  } do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "test_inbound",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-1"}
      })

    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "test_outbound",
        type: "wireguard",
        config: %{"wg_config" => "[Interface]\nPrivateKey = wgpkey\n"}
      })

    # Create active tunnel (active_t) using outbound_profile
    active_pair = %Hermit.Vpn.VpnPair{
      pair_id: "active_t",
      inbound_profile_id: inbound_profile.id,
      outbound_profile_id: outbound_profile.id,
      status: "running",
      wg_status: "running",
      ts_status: "running"
    }

    _ = Hermit.Repo.insert!(active_pair)

    # Create target tunnel (target_t) which is stopped initially
    target_pair = %Hermit.Vpn.VpnPair{
      pair_id: "target_t",
      inbound_profile_id: inbound_profile.id,
      outbound_profile_id: outbound_profile.id,
      status: "stopped",
      wg_status: "stopped",
      ts_status: "stopped"
    }

    _ = Hermit.Repo.insert!(target_pair)

    {:ok, view, _html} = live(conn, ~p"/tunnels/target_t")

    # Click "Start Wireguard" button
    html = view |> element("button", "Start Wireguard") |> render_click()

    assert html =~
             "Failed to start Wireguard: Outbound profile is already in use by active tunnel &#39;active_t&#39;."
  end

  test "toggles exit node and app connector dynamically", %{conn: conn} do
    original_docker_config = Application.get_env(:hermit, :docker)

    Application.put_env(
      :hermit,
      :docker,
      original_docker_config
      |> Keyword.put(:mock_error, nil)
    )

    args = %{
      id: "toggle_test",
      wg_config: "[Interface]\nPrivateKey = wgpkey\n",
      ts_auth_key: "tskey-12345"
    }

    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "test_inbound_ts",
        type: "tailscale",
        config: %{
          "ts_auth_key" => args.ts_auth_key,
          "advertise_exit_node" => true,
          "advertise_connector" => false
        }
      })

    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "test_outbound_wg",
        type: "wireguard",
        config: %{"wg_config" => args.wg_config}
      })

    vpn_pair = %Hermit.Vpn.VpnPair{
      pair_id: args.id,
      inbound_profile_id: inbound_profile.id,
      outbound_profile_id: outbound_profile.id,
      status: "running",
      wg_status: "running",
      ts_status: "running"
    }

    _ = Hermit.Repo.insert!(vpn_pair, on_conflict: :replace_all, conflict_target: :pair_id)

    {:ok, pid} = PairWorker.start_link(args)
    # Simulate worker becoming fully running
    state = GenServer.call(pid, :get_state)

    _running_state = %{
      state
      | wg_status: :running,
        ts_status: :running,
        status: :running,
        metrics: %{state.metrics | ts_backend_state: "Running"}
    }

    # stop so we can register mock/standalone or just run the test
    GenServer.stop(pid)

    # Start a mock running worker
    {:ok, pid} = PairWorker.start_link(args)
    GenServer.call(pid, {:start_wg})
    Process.sleep(100)

    {:ok, view, _html} = live(conn, ~p"/tunnels/toggle_test")

    # Manually broadcast running state to populate detail template fields
    state = GenServer.call(pid, :get_state)

    running_state = %{
      state
      | wg_status: :running,
        ts_status: :running,
        status: :running,
        metrics: %{state.metrics | ts_backend_state: "Running"}
    }

    Phoenix.PubSub.broadcast(Hermit.PubSub, "vpn_pairs", {:vpn_pair_updated, running_state})
    Process.sleep(100)

    html = render(view)
    assert html =~ "Exit Node routing:"
    assert html =~ "Enabled"
    assert html =~ "App Connector:"
    assert html =~ "Disabled"

    # Click Toggle Exit Node button
    # Wait, the toggle button has phx-click="toggle_exit_node"
    html = view |> element("button[phx-click=toggle_exit_node]") |> render_click()
    assert html =~ "Exit node routing disabled"
    assert html =~ "Disabled"

    # Verify DB was updated
    updated_profile = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, inbound_profile.id)
    assert updated_profile.config["advertise_exit_node"] == false

    # Click Toggle App Connector button
    html = view |> element("button[phx-click=toggle_app_connector]") |> render_click()
    assert html =~ "App connector enabled"
    assert html =~ "Enabled"

    # Verify DB was updated
    updated_profile = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, inbound_profile.id)
    assert updated_profile.config["advertise_connector"] == true

    # Submit save_connector_settings form
    html =
      view
      |> form("form[phx-submit=save_connector_settings]", %{
        "connector_tag" => "tag:new-tag",
        "connector_domains" => "google.com, github.com"
      })
      |> render_submit()

    assert html =~ "App Connector settings updated"

    # Verify DB was updated with tag and domains
    updated_profile = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, inbound_profile.id)
    assert updated_profile.config["advertise_connector_tag"] == "tag:new-tag"
    assert updated_profile.config["advertise_connector_domains"] == "google.com, github.com"

    # Toggle off default Tailscale DNS to use custom DNS resolvers
    view |> element("button[phx-click=toggle_use_tailscale_dns]") |> render_click()

    # Submit save_routes_dns_settings form
    html =
      view
      |> form("#save_routes_dns_settings_form", %{
        "dns_resolvers" => "76.76.2.0, 76.76.10.0",
        "advertise_routes" => "192.168.1.0/24"
      })
      |> render_submit()

    assert html =~ "Tailscale routes and DNS settings updated"

    # Verify DB was updated with DNS resolvers and advertise routes
    updated_profile = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, inbound_profile.id)
    assert updated_profile.config["dns_mode"] == "custom"
    assert updated_profile.config["dns_resolvers"] == "76.76.2.0, 76.76.10.0"
    assert updated_profile.config["advertise_routes"] == "192.168.1.0/24"

    # Toggle it back on to use default Tailscale DNS settings
    view |> element("button[phx-click=toggle_use_tailscale_dns]") |> render_click()

    html =
      view
      |> form("#save_routes_dns_settings_form", %{
        "advertise_routes" => "192.168.1.0/24"
      })
      |> render_submit()

    assert html =~ "Tailscale routes and DNS settings updated"

    # Verify DB has default DNS settings
    updated_profile = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, inbound_profile.id)
    assert updated_profile.config["dns_mode"] == "default"
    assert updated_profile.config["dns_resolvers"] == ""

    # Test WireGuard DNS toggle
    html = view |> element("button[phx-click=toggle_wg_use_tailscale_dns]") |> render_click()
    assert html =~ "WireGuard DNS updated"

    # Verify DB was updated
    updated_outbound = Hermit.Repo.get!(Hermit.Vpn.OutboundProfile, outbound_profile.id)
    assert updated_outbound.config["use_tailscale_dns"] == true

    # Toggle back off
    html = view |> element("button[phx-click=toggle_wg_use_tailscale_dns]") |> render_click()
    assert html =~ "WireGuard DNS updated"

    # Verify DB was updated back
    updated_outbound = Hermit.Repo.get!(Hermit.Vpn.OutboundProfile, outbound_profile.id)
    assert updated_outbound.config["use_tailscale_dns"] == false

    Application.put_env(:hermit, :docker, original_docker_config)
    GenServer.stop(pid)
  end

end
