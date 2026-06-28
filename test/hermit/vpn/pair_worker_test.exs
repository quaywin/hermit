defmodule Hermit.Vpn.PairWorkerTest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.PairWorker

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})

    # Configure an invalid socket path so we don't accidentally talk to real Docker
    original_config = Application.get_env(:hermit, :docker)

    Application.put_env(
      :hermit,
      :docker,
      original_config
      |> Keyword.put(:socket_path, "/invalid/docker.sock")
      |> Keyword.put(:mock_error, :daemon_unresponsive)
    )

    # Cleanup storage directory after tests
    storage_dir = Path.expand("storage/test_pair", File.cwd!())
    File.rm_rf!(storage_dir)

    on_exit(fn ->
      Application.put_env(:hermit, :docker, original_config)
      File.rm_rf!(storage_dir)
    end)

    :ok
  end

  test "worker initialization and bootstrap failure when daemon is down" do
    args = %{
      id: "test_pair",
      wg_config: "[Interface]\nPrivateKey = wgpkey\n",
      ts_auth_key: "tskey-12345"
    }

    # Start the worker
    {:ok, pid} = PairWorker.start_link(args)

    # Wait for async bootstrap to run
    Process.sleep(200)

    state = GenServer.call(pid, :get_state)
    assert state.id == "test_pair"
    assert state.status == :error
    assert state.error_reason =~ "WireGuard creation failed: :daemon_unresponsive"

    # Verify sandbox files were created
    assert File.exists?(state.wg_config_path)
    assert File.read!(state.wg_config_path) =~ "PrivateKey = wgpkey"

    # Clean up the process
    GenServer.stop(pid)
  end

  test "resolves Endpoint hostname to IP address in WireGuard configuration" do
    args = %{
      id: "test_pair",
      wg_config: """
      [Interface]
      PrivateKey = wgpkey

      [Peer]
      PublicKey = peerpubkey
      Endpoint = localhost:51820
      """,
      ts_auth_key: "tskey-12345"
    }

    # Start the worker
    {:ok, pid} = PairWorker.start_link(args)

    # Wait for async bootstrap to run
    Process.sleep(200)

    state = GenServer.call(pid, :get_state)

    # Verify configuration file exists and contains resolved IP (127.0.0.1 or ::1) instead of localhost
    assert File.exists?(state.wg_config_path)
    content = File.read!(state.wg_config_path)
    assert content =~ ~r/Endpoint = (127\.0\.0\.1|\[::1\]):51820/

    # Clean up the process
    GenServer.stop(pid)
  end

  test "falls back gracefully when Endpoint hostname fails to resolve" do
    args = %{
      id: "test_pair",
      wg_config: """
      [Interface]
      PrivateKey = wgpkey

      [Peer]
      PublicKey = peerpubkey
      Endpoint = non-existent-domain-xyz-123.com:51820
      """,
      ts_auth_key: "tskey-12345"
    }

    # Start the worker
    {:ok, pid} = PairWorker.start_link(args)

    # Wait for async bootstrap to run
    Process.sleep(200)

    state = GenServer.call(pid, :get_state)

    # Verify configuration file exists and still contains the original Endpoint domain
    assert File.exists?(state.wg_config_path)
    content = File.read!(state.wg_config_path)
    assert content =~ "Endpoint = non-existent-domain-xyz-123.com:51820"

    # Clean up the process
    GenServer.stop(pid)
  end

  test "pausing and resuming worker process" do
    args = %{
      id: "test_pair",
      wg_config: "[Interface]\nPrivateKey = wgpkey\n",
      ts_auth_key: "tskey-12345"
    }

    {:ok, pid} = PairWorker.start_link(args)
    Process.sleep(200)

    # State should be error due to daemon down
    state = GenServer.call(pid, :get_state)
    assert state.status == :error

    # Pause it
    {:ok, state} = GenServer.call(pid, :pause)
    assert state.status == :stopped

    # Resume it (will try to bootstrap again)
    {:ok, state} = GenServer.call(pid, :resume)
    assert state.status == :starting_wg

    GenServer.stop(pid)
  end

  test "automatically attempts to recover Tailscale when port exits unexpectedly" do
    original_config = Application.get_env(:hermit, :docker)

    Application.put_env(
      :hermit,
      :docker,
      original_config
      |> Keyword.put(:socket_path, "/invalid/docker.sock")
      |> Keyword.put(:mock_error, nil)
    )

    on_exit(fn ->
      Application.put_env(:hermit, :docker, original_config)
      File.rm_rf!(Path.expand("storage/test_pair_ts_recovery", File.cwd!()))
    end)

    args = %{
      id: "test_pair_ts_recovery",
      wg_config: "[Interface]\nPrivateKey = wgpkey\n",
      ts_auth_key: "tskey-12345"
    }

    # Persist the pair in Ecto so get_state can query it during recovery
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
    # Wait for bootstrap to complete and transition to running
    Process.sleep(300)

    state = GenServer.call(pid, :get_state)
    assert state.status == :running
    assert state.wg_status == :running
    assert state.ts_status == :running
    assert is_port(state.ts_port)

    # Simulate TS port exit
    send(pid, {:EXIT, state.ts_port, :killed})
    Process.sleep(100)

    # State should now be error for ts, with overall status as error
    state = GenServer.call(pid, :get_state)
    assert state.status == :error
    assert state.ts_status == :error
    assert state.ts_error_reason =~ "Tailscale daemon exited unexpectedly"

    # Wait for recovery (5 seconds cooldown + some buffer)
    Process.sleep(5200)

    # State should be running again!
    state = GenServer.call(pid, :get_state)
    assert state.status == :running
    assert state.wg_status == :running
    assert state.ts_status == :running

    GenServer.stop(pid)
  end

  test "automatically attempts to recover WireGuard when namespace goes down" do
    original_config = Application.get_env(:hermit, :docker)

    Application.put_env(
      :hermit,
      :docker,
      original_config
      |> Keyword.put(:socket_path, "/invalid/docker.sock")
      |> Keyword.put(:mock_error, nil)
    )

    on_exit(fn ->
      Application.put_env(:hermit, :docker, original_config)
      File.rm_rf!(Path.expand("storage/test_pair_wg_recovery", File.cwd!()))
    end)

    args = %{
      id: "test_pair_wg_recovery",
      wg_config: "[Interface]\nPrivateKey = wgpkey\n",
      ts_auth_key: "tskey-12345"
    }

    # Persist the pair in Ecto so get_state can query it during recovery
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
    Process.sleep(300)

    state = GenServer.call(pid, :get_state)
    assert state.status == :running

    # Delete storage directory to simulate WireGuard namespace disappearing (mock logic checks File.exists?)
    File.rm_rf!(state.storage_dir)

    # Force a metrics poll
    send(pid, :poll_metrics)
    Process.sleep(100)

    # State should now transition to error for wg, overall status as error
    state = GenServer.call(pid, :get_state)
    assert state.status == :error
    assert state.wg_status == :error
    assert state.wg_error_reason =~ "WireGuard namespace went down unexpectedly"

    # Wait for recovery (5 seconds cooldown + some buffer)
    Process.sleep(5200)

    # State should be running again!
    state = GenServer.call(pid, :get_state)
    assert state.status == :running
    assert state.wg_status == :running

    GenServer.stop(pid)
  end

  test "updates WireGuard configuration dynamically and saves to database" do
    args = %{
      id: "test_pair",
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

    vpn_pair = %Hermit.Vpn.VpnPair{
      pair_id: args.id,
      inbound_profile_id: inbound_profile.id,
      outbound_profile_id: outbound_profile.id,
      status: "running",
      wg_status: "stopped",
      ts_status: "stopped"
    }

    _ = Hermit.Repo.insert!(vpn_pair, on_conflict: :replace_all, conflict_target: :pair_id)

    {:ok, pid} = PairWorker.start_link(args)
    Process.sleep(200)

    # 1. Update when offline / GenServer not running - wait, GenServer is running here.
    new_config = "[Interface]\nPrivateKey = newpkey\nAddress = 10.0.0.3/24\n"
    assert {:ok, _} = PairWorker.update_wg_config("test_pair", new_config)

    # Check database was updated
    updated_pair = Hermit.Repo.get!(Hermit.Vpn.VpnPair, "test_pair")

    updated_profile =
      Hermit.Repo.get!(Hermit.Vpn.OutboundProfile, updated_pair.outbound_profile_id)

    assert updated_profile.config["wg_config"] == new_config

    # Check memory state of running worker
    state = GenServer.call(pid, :get_state)
    assert state.wg_config_content == new_config

    # Check file on disk was updated
    assert File.read!(state.wg_config_path) =~ "PrivateKey = newpkey"

    GenServer.stop(pid)
  end

  test "initializes inbound and outbound configurations with custom login server" do
    args = %{
      id: "test_pair",
      wg_config: "[Interface]\nPrivateKey = wgpkey\n",
      ts_auth_key: "tskey-12345",
      login_server: "https://my-headscale.com"
    }

    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "test_inbound_ts",
        type: "tailscale",
        config: %{"ts_auth_key" => args.ts_auth_key, "login_server" => args.login_server}
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
      wg_status: "stopped",
      ts_status: "stopped"
    }

    _ = Hermit.Repo.insert!(vpn_pair, on_conflict: :replace_all, conflict_target: :pair_id)

    {:ok, pid} = PairWorker.start_link(args)
    Process.sleep(200)

    state = GenServer.call(pid, :get_state)
    assert state.inbound_config["login_server"] == "https://my-headscale.com"
    assert state.inbound_config["ts_auth_key"] == "tskey-12345"

    GenServer.stop(pid)
  end

  test "stop_wg stops inbound (Tailscale) and resets metrics to default keys" do
    original_config = Application.get_env(:hermit, :docker)

    Application.put_env(
      :hermit,
      :docker,
      original_config
      |> Keyword.put(:socket_path, "/invalid/docker.sock")
      |> Keyword.put(:mock_error, nil)
    )

    on_exit(fn ->
      Application.put_env(:hermit, :docker, original_config)
      File.rm_rf!(Path.expand("storage/test_pair_stop_wg", File.cwd!()))
    end)

    args = %{
      id: "test_pair_stop_wg",
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
      status: "running",
      wg_status: "starting",
      ts_status: "starting"
    }

    _ = Hermit.Repo.insert!(vpn_pair, on_conflict: :replace_all, conflict_target: :pair_id)

    {:ok, pid} = PairWorker.start_link(args)
    # Wait for bootstrap to complete and transition to running
    Process.sleep(300)

    # Confirm it is running and ts_port is active
    state = GenServer.call(pid, :get_state)
    assert state.wg_status == :running
    assert state.ts_status == :running
    assert is_port(state.ts_port)

    # Perform stop_wg
    {:ok, state} = GenServer.call(pid, {:stop_wg})

    # Assert both wg and ts are stopped
    assert state.wg_status == :stopped
    assert state.ts_status == :stopped
    assert is_nil(state.ts_port)

    # Assert metrics have default keys and values (e.g. ts_backend_state is "Offline")
    assert state.metrics.ts_backend_state == "Offline"
    assert state.metrics.ts_user == "Unknown"
    assert state.metrics.ts_ips == []

    GenServer.stop(pid)
  end

  test "bootstrap fails if outbound profile is already in use by another active tunnel" do
    wg_config = "[Interface]\nPrivateKey = wgpkey\n"
    ts_auth_key = "tskey-12345"

    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "test_inbound_conflict",
        type: "tailscale",
        config: %{"ts_auth_key" => ts_auth_key}
      })

    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "test_outbound_conflict",
        type: "wireguard",
        config: %{"wg_config" => wg_config}
      })

    # Create active pair_a in the database using the same profile
    pair_a = %Hermit.Vpn.VpnPair{
      pair_id: "pair_a",
      inbound_profile_id: inbound_profile.id,
      outbound_profile_id: outbound_profile.id,
      status: "running",
      wg_status: "running",
      ts_status: "running"
    }

    _ = Hermit.Repo.insert!(pair_a)

    # Create pair_b in the database that will try to start
    pair_b = %Hermit.Vpn.VpnPair{
      pair_id: "pair_b",
      inbound_profile_id: inbound_profile.id,
      outbound_profile_id: outbound_profile.id,
      status: "running",
      wg_status: "starting",
      ts_status: "starting"
    }

    _ = Hermit.Repo.insert!(pair_b)

    args = %{
      id: "pair_b",
      wg_config: wg_config,
      ts_auth_key: ts_auth_key
    }

    # Start the worker for pair_b
    {:ok, pid} = PairWorker.start_link(args)
    # Wait for bootstrap
    Process.sleep(250)

    # Verify that the worker failed to bootstrap because the profile is in use by pair_a
    state = GenServer.call(pid, :get_state)
    assert state.wg_status == :error

    assert state.wg_error_reason ==
             "Outbound profile is already in use by active tunnel 'pair_a'."

    GenServer.stop(pid)
  end

  test "starting WireGuard alone starts the metrics timer and schedules poll" do
    original_config = Application.get_env(:hermit, :docker)

    Application.put_env(
      :hermit,
      :docker,
      original_config
      |> Keyword.put(:socket_path, "/invalid/docker.sock")
      |> Keyword.put(:mock_error, nil)
    )

    on_exit(fn ->
      Application.put_env(:hermit, :docker, original_config)
      File.rm_rf!(Path.expand("storage/test_pair_start_wg_alone", File.cwd!()))
    end)

    args = %{
      id: "test_pair_start_wg_alone",
      wg_config: "[Interface]\nPrivateKey = wgpkey\n",
      ts_auth_key: "tskey-12345"
    }

    # Persist the pair with wg_status = stopped and ts_status = stopped
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "test_inbound_ts_alone",
        type: "tailscale",
        config: %{"ts_auth_key" => args.ts_auth_key}
      })

    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "test_outbound_wg_alone",
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

    {:ok, pid} = PairWorker.start_link(args)
    Process.sleep(200)

    # Initial state should be stopped for both
    state = GenServer.call(pid, :get_state)
    assert state.wg_status == :stopped
    assert state.ts_status == :stopped
    assert is_nil(state.metrics_timer)

    # Start WireGuard
    {:ok, _updated_state} = GenServer.call(pid, {:start_wg})
    # Wait for bootstrap_wg continue to run
    Process.sleep(300)

    state = GenServer.call(pid, :get_state)
    assert state.wg_status == :running
    assert state.ts_status == :stopped
    # The metrics timer should be active
    assert is_reference(state.metrics_timer)

    # Stop WireGuard
    {:ok, state} = GenServer.call(pid, {:stop_wg})
    assert state.wg_status == :stopped
    # The metrics timer should be cancelled (nil)
    assert is_nil(state.metrics_timer)

    GenServer.stop(pid)
  end
end
