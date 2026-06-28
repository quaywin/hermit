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
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "HERMIT GATEWAY"

    # 1. Test validation error
    invalid_form = %{
      "form" => %{
        "pair_id" => "invalid Name Here",
        "wg_config" => ""
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
        "wg_config" => "[Interface]\nPrivateKey = test_key\n"
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
end
