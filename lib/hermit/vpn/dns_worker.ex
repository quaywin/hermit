defmodule Hermit.Vpn.DnsWorker do
  use GenServer
  require Logger

  # State:
  # - :endpoint_id (integer)
  # - :inbound_profile_id (integer | nil)
  # - :status (:stopped | :starting | :running | :error)
  # - :error_reason (nil | string)
  # - :ts_ip (nil | string)
  # - :ts_port (nil | port/pid)
  # - :mock_timer (nil | timer)
  defstruct endpoint_id: nil,
            inbound_profile_id: nil,
            status: :stopped,
            error_reason: nil,
            ts_ip: nil,
            ts_port: nil,
            mock_timer: nil,
            tailscale_override_dns: false,
            last_dns_sync_signature: nil,
            last_synced_upstreams: [],
            subscribed_profile_id: nil,
            dns_sync_status: :idle

  # --- Client API ---

  def start_link(opts) do
    endpoint_id = opts[:endpoint_id]
    name = {:via, Registry, {Hermit.Vpn.Registry, {:dns_worker, endpoint_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def sync_state(endpoint_id) do
    case Registry.lookup(Hermit.Vpn.Registry, {:dns_worker, endpoint_id}) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :sync_state, 45_000)
        catch
          :exit, _ -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  def get_status(endpoint_id) do
    case Registry.lookup(Hermit.Vpn.Registry, {:dns_worker, endpoint_id}) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :get_status)
        catch
          :exit, _ -> {:stopped, nil, nil}
        end

      [] ->
        {:stopped, nil, nil}
    end
  end

  def get_dns_sync_status(endpoint_id) do
    case Registry.lookup(Hermit.Vpn.Registry, {:dns_worker, endpoint_id}) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :get_dns_sync_status)
        catch
          :exit, _ -> :idle
        end

      [] ->
        :idle
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    endpoint_id = opts[:endpoint_id]
    inbound_profile_id = opts[:inbound_profile_id]

    subscribed_profile_id =
      if :erlang.whereis(Hermit.PubSub) != :undefined do
        try do
          Phoenix.PubSub.subscribe(Hermit.PubSub, "smart_routes")
          config = Hermit.Vpn.DnsConfig.get_for_endpoint(endpoint_id)

          if config.id do
            Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_config_profile:#{config.id}")
            config.id
          end
        rescue
          _ -> nil
        end
      end

    # Perform initial sync on startup
    send(self(), :initial_sync)

    {:ok,
     %__MODULE__{
       endpoint_id: endpoint_id,
       inbound_profile_id: inbound_profile_id,
       subscribed_profile_id: subscribed_profile_id
     }}
  end

  @impl true
  def handle_call(:sync_state, _from, state) do
    {reply, new_state} = do_sync_state(state)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, {state.status, state.ts_ip, state.error_reason}, state}
  end

  @impl true
  def handle_call(:get_dns_sync_status, _from, state) do
    {:reply, state.dns_sync_status, state}
  end

  @impl true
  def handle_info(:initial_sync, state) do
    {_, new_state} = do_sync_state(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:dns_config_updated, _updated_config}, state) do
    {_, new_state} = do_sync_state(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:smart_routes_updated, _all_pairs}, state) do
    {_, new_state} = do_sync_state(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:dns_sync_result, result}, state) do
    new_sync_status =
      case result do
        {:ok, :updated} -> :synced
        {:ok, :cleared} -> :idle
        {:ok, :noop} -> :idle
        {:error, reason} -> {:error, format_dns_sync_error(reason)}
      end

    {:noreply, %{state | dns_sync_status: new_sync_status}}
  end

  @impl true
  def handle_info({:dns_node_start_result, result}, state) do
    if state.status == :starting do
      case result do
        {:ok, ip, port} ->
          # Get current config to check if override is enabled
          config = Hermit.Vpn.DnsConfig.get_for_endpoint(state.endpoint_id)
          state = maybe_sync_profile_subscription(state, config.id)

          profile =
            if state.inbound_profile_id,
              do: Hermit.Repo.get(Hermit.Vpn.InboundProfile, state.inbound_profile_id)

          mock_timer =
            if mock?() do
              Process.send_after(self(), :generate_mock_log, 1000)
            else
              nil
            end

          new_sig = dns_sync_signature(config, profile)

          plan =
            if config.tailscale_override_dns,
              do: build_sync_plan(config, nil, [], profile),
              else: nil

          synced_upstreams =
            if plan && plan.mode == :split,
              do: plan.upstream_resolvers,
              else: []

          sync_started? = config.tailscale_override_dns and not is_nil(profile)

          new_state = %{
            state
            | status: :running,
              ts_ip: ip,
              ts_port: port,
              error_reason: nil,
              mock_timer: mock_timer,
              tailscale_override_dns: config.tailscale_override_dns,
              last_dns_sync_signature: new_sig,
              last_synced_upstreams: synced_upstreams,
              dns_sync_status: if(sync_started?, do: :syncing, else: :idle)
          }

          if sync_started? do
            parent = self()

            spawn(fn ->
              res = update_tailscale_dns_config(ip, profile, config)
              send(parent, {:dns_sync_result, res})
            end)
          end

          {:noreply, new_state}

        {:error, reason} ->
          new_state = %{state | status: :error, error_reason: inspect(reason)}
          maybe_schedule_recovery(new_state)
          {:noreply, new_state}
      end
    else
      # If status is not :starting (e.g. stopped while bootstrap was in progress), clean up
      case result do
        {:ok, _ip, _port} ->
          new_state = stop_dns_node(state)
          {:noreply, new_state}

        {:error, _reason} ->
          {:noreply, state}
      end
    end
  end

  @impl true
  def handle_info(:retry_start_dns_node, state) do
    endpoint = Hermit.Repo.get(Hermit.Vpn.DnsEndpoint, state.endpoint_id)

    if (endpoint && endpoint.enabled) and state.status in [:error, :stopped] do
      Logger.info("Attempting auto-recovery for DNS node (endpoint #{state.endpoint_id})...")
      {_res, new_state} = do_sync_state(state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:generate_mock_log, state) do
    if mock?() and state.status == :running do
      spawn(fn ->
        send_mock_query(state.endpoint_id)
      end)
    end

    timer = Process.send_after(self(), :generate_mock_log, 3000)
    {:noreply, %{state | mock_timer: timer}}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, state) do
    if port == state.ts_port do
      Logger.error("DNS Tailscale daemon process exited: #{inspect(reason)}")

      new_state = %{
        state
        | status: :error,
          error_reason: "Daemon exited: #{inspect(reason)}",
          ts_port: nil
      }

      maybe_schedule_recovery(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.tailscale_override_dns do
      profile =
        if state.inbound_profile_id,
          do: Hermit.Repo.get(Hermit.Vpn.InboundProfile, state.inbound_profile_id)

      config = Hermit.Vpn.DnsConfig.get_for_endpoint(state.endpoint_id)

      if profile do
        ts_ip = state.ts_ip
        extra_upstreams = state.last_synced_upstreams
        Task.start(fn -> clear_tailscale_dns_config(profile, config, ts_ip, extra_upstreams) end)
      end
    end

    stop_dns_node(state)
  end

  @doc false
  def format_dns_sync_error({:http_error, 403, _}),
    do: "HTTP 403: OAuth key missing 'dns' (read/write) scope"

  def format_dns_sync_error({:http_error, status, %{"message" => msg}}) when is_binary(msg),
    do: "HTTP #{status}: #{msg}"

  def format_dns_sync_error({:http_error, status, _}),
    do: "HTTP #{status} from Tailscale API"

  def format_dns_sync_error(:unsupported_auth_key),
    do: "Pre-auth key (tskey-auth-) cannot update Tailscale DNS API; use OAuth (tskey-client-)"

  def format_dns_sync_error(:empty_key),
    do: "Tailscale API/OAuth key is not configured"

  def format_dns_sync_error(:unknown_key_format),
    do: "Unrecognized Tailscale key format"

  def format_dns_sync_error({:oauth_failed, status, _}),
    do: "Tailscale OAuth token exchange failed (HTTP #{status})"

  def format_dns_sync_error(:empty_dns_ip),
    do: "Endpoint Tailscale IP is not ready"

  def format_dns_sync_error(%{__exception__: true} = exc),
    do: Exception.message(exc)

  def format_dns_sync_error(other),
    do: inspect(other)

  # --- Internal Lifecycle Management ---

  defp do_sync_state(state) do
    profile =
      if state.inbound_profile_id,
        do: Hermit.Repo.get(Hermit.Vpn.InboundProfile, state.inbound_profile_id)

    config = Hermit.Vpn.DnsConfig.get_for_endpoint(state.endpoint_id)
    state = maybe_sync_profile_subscription(state, config.id)
    endpoint = Hermit.Repo.get!(Hermit.Vpn.DnsEndpoint, state.endpoint_id)

    cond do
      endpoint.enabled and state.status in [:stopped, :error] ->
        if is_nil(profile) do
          Logger.error(
            "DNS Server is enabled for endpoint #{state.endpoint_id} but inbound profile is nil or not found."
          )

          {{:error, :profile_not_found},
           %{state | status: :error, error_reason: "Profile not found"}}
        else
          Logger.info(
            "DNS Server is enabled for endpoint #{state.endpoint_id}. Ensuring Dedicated DNS Node is running..."
          )

          parent = self()
          # Spawn the asynchronous bootstrap process
          spawn_link(fn ->
            res = start_dns_node_async(state.endpoint_id, profile)
            send(parent, {:dns_node_start_result, res})
          end)

          {{:ok, :starting}, %{state | status: :starting, error_reason: nil}}
        end

      not endpoint.enabled and state.status in [:running, :starting, :error] ->
        Logger.info(
          "DNS Server is disabled for endpoint #{state.endpoint_id}. Putting DNS Node offline..."
        )

        ts_ip = state.ts_ip
        extra_upstreams = state.last_synced_upstreams
        new_state = stop_dns_node(state)

        if (config.tailscale_override_dns or state.tailscale_override_dns == true) and profile do
          spawn(fn -> clear_tailscale_dns_config(profile, config, ts_ip, extra_upstreams) end)
        end

        {{:ok, :stopped},
         %{
           new_state
           | tailscale_override_dns: false,
             last_dns_sync_signature: :disabled,
             last_synced_upstreams: [],
             dns_sync_status: :idle
         }}

      endpoint.enabled and state.status == :running ->
        new_sig = dns_sync_signature(config, profile)

        if state.tailscale_override_dns != config.tailscale_override_dns or
             state.last_dns_sync_signature != new_sig do
          extra_upstreams = state.last_synced_upstreams
          parent = self()

          {next_upstreams, next_sync_status} =
            if config.tailscale_override_dns and profile do
              plan = build_sync_plan(config, nil, extra_upstreams, profile)

              spawn(fn ->
                res = update_tailscale_dns_config(state.ts_ip, profile, config, extra_upstreams)
                send(parent, {:dns_sync_result, res})
              end)

              {if(plan.mode == :split, do: plan.upstream_resolvers, else: []), :syncing}
            else
              if state.tailscale_override_dns and profile do
                ts_ip = state.ts_ip

                spawn(fn ->
                  res = clear_tailscale_dns_config(profile, config, ts_ip, extra_upstreams)
                  send(parent, {:dns_sync_result, res})
                end)
              end

              {[], :idle}
            end

          {{:ok, :updated_dns_integration},
           %{
             state
             | tailscale_override_dns: config.tailscale_override_dns and not is_nil(profile),
               last_dns_sync_signature: new_sig,
               last_synced_upstreams: next_upstreams,
               dns_sync_status: next_sync_status
           }}
        else
          {{:ok, :already_synced}, state}
        end

      true ->
        {{:ok, :already_synced}, state}
    end
  end

  defp maybe_sync_profile_subscription(state, new_profile_id) do
    if new_profile_id != state.subscribed_profile_id and
         :erlang.whereis(Hermit.PubSub) != :undefined do
      if state.subscribed_profile_id do
        Phoenix.PubSub.unsubscribe(
          Hermit.PubSub,
          "dns_config_profile:#{state.subscribed_profile_id}"
        )
      end

      if new_profile_id do
        Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_config_profile:#{new_profile_id}")
      end

      %{state | subscribed_profile_id: new_profile_id}
    else
      state
    end
  end

  defp maybe_schedule_recovery(state) do
    endpoint = Hermit.Repo.get(Hermit.Vpn.DnsEndpoint, state.endpoint_id)

    if (endpoint && endpoint.enabled) and not mock?() do
      Logger.info(
        "Scheduling DNS node recovery for endpoint #{state.endpoint_id} in 5 seconds..."
      )

      Process.send_after(self(), :retry_start_dns_node, 5000)
    end
  end

  defp get_dns_credentials(profile) do
    profile_config = (profile && profile.config) || %{}

    auth_key =
      Map.get(profile_config, "ts_auth_key") ||
        Map.get(profile_config, :ts_auth_key) ||
        Map.get(profile_config, "ts_api_key") ||
        Map.get(profile_config, :ts_api_key) ||
        System.get_env("TAILSCALE_AUTH_KEY") ||
        System.get_env("TS_AUTHKEY") ||
        System.get_env("TAILSCALE_API_KEY") ||
        System.get_env("TS_API_KEY") ||
        Hermit.Vpn.Setting.get_value("tailscale_api_key", "") ||
        (Application.get_env(:hermit, :docker) &&
           Application.get_env(:hermit, :docker)[:tailscale_auth_key]) ||
        ""

    tailnet =
      Map.get(profile_config, "ts_tailnet") ||
        Map.get(profile_config, :ts_tailnet) ||
        Hermit.Vpn.Setting.get_value("tailscale_tailnet", "") ||
        "-"

    tailnet = if tailnet == "", do: "-", else: tailnet
    login_server = Map.get(profile_config, "login_server") || ""

    {auth_key, tailnet, login_server}
  end

  defp start_dns_node_async(endpoint_id, profile) do
    if mock?() do
      {:ok, "100.64.0.100", nil}
    else
      storage_dir = Path.join(get_storage_base_path(), "dns_#{endpoint_id}")
      File.mkdir_p!(storage_dir)

      profile_config = (profile && profile.config) || %{}
      {auth_key, _tailnet, login_server} = get_dns_credentials(profile)

      if auth_key == "" do
        {:error, "Tailscale auth key not configured"}
      else
        case bootstrap_namespace(endpoint_id, storage_dir, auth_key, login_server, profile_config) do
          {:ok, port, ip} ->
            {:ok, ip, port}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp stop_dns_node(state) do
    if state.mock_timer, do: Process.cancel_timer(state.mock_timer)

    if mock?() do
      %{state | status: :stopped, ts_ip: nil, mock_timer: nil}
    else
      # Thay vì cleanup_namespace(endpoint_id) và dừng hẳn tailscaled daemon,
      # ta chỉ mang node tailscale down. Namespace và daemon vẫn giữ nguyên.
      # Điều này tối ưu tốc độ kết nối/ngắt kết nối mà không cần tạo/xóa network interface liên tục.
      ns = "hermit_dns_endpoint_#{state.endpoint_id}"
      socket_path = "/run/tailscaled.dns_#{state.endpoint_id}.socket"

      if netns_exists?(ns) do
        _ =
          run_cmd("ip", [
            "netns",
            "exec",
            ns,
            "tailscale",
            "--socket=#{socket_path}",
            "down"
          ])
      end

      # Trạng thái DNS worker chuyển sang :stopped nhưng ta giữ nguyên ts_port và các tài nguyên
      %{state | status: :stopped, ts_ip: nil, mock_timer: nil, error_reason: nil}
    end
  end

  # --- Namespace Setup & Linux Commands ---

  defp bootstrap_namespace(endpoint_id, storage_dir, auth_key, login_server, profile_config) do
    ns = "hermit_dns_endpoint_#{endpoint_id}"
    host_if = "dns_h_#{endpoint_id}"
    table_id = 1000 + endpoint_id
    octet = (max(endpoint_id, 1) - 1) |> rem(250)
    host_ip = "10.251.#{octet}.1"
    subnet = "10.251.#{octet}.0/30"
    port = 5400 + endpoint_id
    ts_port = Hermit.Vpn.Inbound.Tailscale.resolve_port("dns_#{endpoint_id}", profile_config)
    host_ts_ip = Hermit.Vpn.Inbound.Tailscale.get_host_tailscale_ip()

    socket_path = "/run/tailscaled.dns_#{endpoint_id}.socket"
    pid_path = Path.join(storage_dir, "tailscaled.pid")

    daemon_running =
      case File.read(pid_path) do
        {:ok, pid_str} ->
          pid = String.trim(pid_str)
          File.exists?("/proc/#{pid}")

        _ ->
          false
      end

    # Nếu namespace và tailscaled daemon socket đã tồn tại/đang chạy và namespace có thể sử dụng được, ta không cần bootstrap lại từ đầu
    has_existing_env =
      netns_exists?(ns) and
        netns_usable?(ns) and
        File.exists?(socket_path) and
        daemon_running

    setup_result =
      if has_existing_env do
        if is_binary(host_ts_ip) and host_ts_ip != "" do
          case run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "nft",
                 "list",
                 "chain",
                 "ip",
                 "hermit_ns",
                 "postrouting"
               ]) do
            {:ok, output} ->
              unless String.contains?(output, host_ts_ip) do
                _ =
                  run_cmd("ip", [
                    "netns",
                    "exec",
                    ns,
                    "nft",
                    "add",
                    "rule",
                    "ip",
                    "hermit_ns",
                    "postrouting",
                    "ip",
                    "saddr",
                    host_ts_ip,
                    "oifname",
                    "eth0",
                    "masquerade"
                  ])
              end

            _ ->
              :ok
          end
        end

        :ok
      else
        cleanup_namespace(endpoint_id)

        # Setup isolated resolv.conf for the namespace to prevent tailscaled from overwriting host resolv.conf
        netns_dns_dir = "/etc/netns/#{ns}"
        File.mkdir_p!(netns_dns_dir)

        if File.exists?("/etc/resolv.conf") do
          case File.read("/etc/resolv.conf") do
            {:ok, resolv_content} ->
              final_content = build_resolv_conf(resolv_content)
              File.write!(Path.join(netns_dns_dir, "resolv.conf"), final_content)

            _ ->
              File.write!(
                Path.join(netns_dns_dir, "resolv.conf"),
                "nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
              )
          end
        else
          File.write!(
            Path.join(netns_dns_dir, "resolv.conf"),
            "nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
          )
        end

        with {:ok, %{ns_ip: ns_ip}} <-
               Hermit.Vpn.Namespace.create_endpoint_namespace(endpoint_id, ts_port),
             {:ok, _} <-
               run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "ip",
                 "link",
                 "set",
                 "eth0",
                 "mtu",
                 "1400"
               ]),
             {:ok, _} <-
               run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "sysctl",
                 "-w",
                 "net.ipv4.ip_forward=1",
                 "net.ipv6.conf.all.forwarding=1",
                 "net.ipv4.conf.all.rp_filter=0",
                 "net.ipv4.conf.default.rp_filter=0",
                 "net.ipv4.conf.eth0.rp_filter=0"
               ]),
             {:ok, _} <-
               run_cmd("sysctl", [
                 "-w",
                 "net.ipv4.conf.#{host_if}.rp_filter=0"
               ]),
             {:ok, _} <-
               run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "ip",
                 "route",
                 "add",
                 "default",
                 "via",
                 host_ip,
                 "dev",
                 "eth0"
               ]),
             # NAT routing on Host via unified Hermit.Vpn.Nat module
             :ok <-
               Hermit.Vpn.Nat.setup_nat(
                 "hermit_dns_endpoint_#{endpoint_id}",
                 subnet,
                 ns_ip,
                 ts_port
               ),
             # DNAT port redirection inside namespace using nftables
             {:ok, _} <-
               setup_dns_nftables(ns, host_ip, port, storage_dir, host_ts_ip),

             # Source policy routing on host (replacing global route)
             {:ok, _} <-
               run_cmd("ip", [
                 "rule",
                 "add",
                 "from",
                 host_ip,
                 "to",
                 "100.64.0.0/10",
                 "table",
                 to_string(table_id)
               ]),
             {:ok, _} <-
               run_cmd("ip", [
                 "route",
                 "add",
                 "default",
                 "via",
                 ns_ip,
                 "dev",
                 host_if,
                 "table",
                 to_string(table_id)
               ]) do
          # Apply UDP GRO forwarding optimizations (gracefully)
          case run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "ethtool",
                 "-K",
                 "eth0",
                 "rx-udp-gro-forwarding",
                 "on",
                 "rx-gro-list",
                 "off"
               ]) do
            {:ok, _} ->
              Logger.info("Successfully enabled UDP GRO forwarding on eth0 in namespace #{ns}")

            {:error, reason} ->
              Logger.warning(
                "Could not enable UDP GRO forwarding on eth0 in namespace #{ns}: #{inspect(reason)}. Continuing without GRO optimization."
              )
          end

          :ok
        else
          {:error, reason} -> {:error, reason}
        end
      end

    case setup_result do
      :ok ->
        state_path = Path.join(storage_dir, "tailscaled.state")
        pid_path = Path.join(storage_dir, "tailscaled.pid")

        daemon_port =
          if has_existing_env do
            # Nếu daemon đã chạy từ trước, ta tái sử dụng port cũ hoặc tìm lại (Elixir port được coi là nil hoặc đã được giữ trong state)
            # Vì state được truyền vào là state cũ nhưng khi stop ta chỉ giữ trong GenServer state.
            nil
          else
            File.rm(socket_path)
            log_path = Path.join(storage_dir, "tailscaled.log")
            _ = File.rm(log_path)

            ts_port =
              Hermit.Vpn.Inbound.Tailscale.resolve_port("dns_#{endpoint_id}", profile_config)

            Hermit.Vpn.Inbound.Tailscale.claim_port("dns_#{endpoint_id}", ts_port)

            shell_cmd =
              "GOMEMLIMIT=32MiB GOGC=50 ip netns exec #{ns} tailscaled --socket=#{socket_path} --state=#{state_path} --port=#{ts_port} --no-logs-no-support > #{log_path} 2>&1 & echo $! > #{pid_path} && wait"

            try do
              p = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", shell_cmd]])

              wait_for_socket(socket_path)
              p
            rescue
              e -> raise e
            end
          end

        try do
          # Wait for DNS/Network resolution inside the namespace to be ready
          hosts =
            if login_server && login_server != "" do
              case URI.parse(login_server) do
                %URI{host: host} when is_binary(host) -> [host, "controlplane.tailscale.com"]
                _ -> ["controlplane.tailscale.com"]
              end
            else
              ["controlplane.tailscale.com"]
            end

          wait_for_dns_resolve(ns, hosts)

          ts_up_args = [
            "netns",
            "exec",
            ns,
            "tailscale",
            "--socket=#{socket_path}",
            "up",
            "--reset",
            "--authkey=#{auth_key}",
            "--accept-dns=false",
            "--accept-routes=false",
            "--stateful-filtering=false",
            "--hostname=hermit-dns-#{endpoint_id}",
            "--timeout=30s"
          ]

          ts_up_args =
            if login_server && login_server != "" do
              ts_up_args ++ ["--login-server=#{login_server}"]
            else
              ts_up_args
            end

          dns_tag =
            Hermit.Vpn.Inbound.Tailscale.resolve_tags("dns_#{endpoint_id}", profile_config, %{
              ts_auth_key: auth_key
            })

          ts_up_args =
            if dns_tag != nil do
              ts_up_args ++ ["--advertise-tags=#{dns_tag}"]
            else
              ts_up_args
            end

          case run_cmd("ip", ts_up_args) do
            {:ok, _} ->
              # Avoid masquerading DNS query packets forwarded from tailscale0 to host (chỉ chạy khi khởi tạo mới)
              if not has_existing_env do
                _ =
                  run_cmd("ip", [
                    "netns",
                    "exec",
                    ns,
                    "nft",
                    "insert",
                    "rule",
                    "ip",
                    "hermit_ns",
                    "postrouting",
                    "ip",
                    "daddr",
                    host_ip,
                    "meta",
                    "mark",
                    "set",
                    "0"
                  ])
              end

              case System.cmd("ip", [
                     "netns",
                     "exec",
                     ns,
                     "tailscale",
                     "--socket=#{socket_path}",
                     "ip",
                     "-4"
                   ]) do
                {ip_out, 0} ->
                  ip = String.trim(ip_out)
                  {:ok, daemon_port, ip}

                _ ->
                  {:error, "Failed to retrieve Tailscale IP"}
              end

            {:error, reason} ->
              if not has_existing_env do
                stop_tailscaled_by_pid(pid_path)
                File.rm(socket_path)
              end

              {:error, {:tailscale_up_failed, reason}}
          end
        rescue
          e -> {:error, {:spawn_failed, e}}
        end

      {:error, reason} ->
        cleanup_namespace(endpoint_id)
        {:error, reason}
    end
  end

  defp cleanup_namespace(endpoint_id) do
    table_id = 1000 + endpoint_id
    octet = (max(endpoint_id, 1) - 1) |> rem(250)
    host_ip = "10.251.#{octet}.1"

    try do
      System.cmd(
        "ip",
        [
          "rule",
          "delete",
          "from",
          host_ip,
          "to",
          "100.64.0.0/10",
          "table",
          to_string(table_id)
        ],
        stderr_to_stdout: true
      )

      System.cmd(
        "ip",
        [
          "route",
          "flush",
          "table",
          to_string(table_id)
        ],
        stderr_to_stdout: true
      )
    rescue
      _ -> :ok
    end

    Hermit.Vpn.Namespace.destroy_endpoint_namespace(endpoint_id)
  end

  # --- Tailscale DNS Config API Update (HA Multi-Nameservers) ---

  @doc """
  Appends an IP address to the existing nameservers list.
  Returns a unique list of IP strings.
  """
  def append_resolver(resolvers, dns_ip)
      when is_list(resolvers) and is_binary(dns_ip) and dns_ip != "" do
    existing_ips =
      Enum.map(resolvers, fn
        %{"address" => addr} -> addr
        %{address: addr} -> addr
        %{"addr" => addr} -> addr
        %{addr: addr} -> addr
        addr when is_binary(addr) -> addr
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    Enum.uniq(existing_ips ++ [dns_ip])
  end

  def append_resolver(resolvers, _), do: resolvers

  @doc """
  Removes a specific IP address from the nameservers list while preserving all other nameservers.
  Returns a list of IP strings.
  """
  def remove_resolver(resolvers, nil), do: resolvers

  def remove_resolver(resolvers, dns_ip) when is_list(resolvers) and is_binary(dns_ip) do
    resolvers
    |> Enum.map(fn
      %{"address" => addr} -> addr
      %{address: addr} -> addr
      %{"addr" => addr} -> addr
      %{addr: addr} -> addr
      addr when is_binary(addr) -> addr
      other -> other
    end)
    |> Enum.reject(fn addr -> addr == dns_ip or is_nil(addr) end)
  end

  def remove_resolver(resolvers, _), do: resolvers

  @doc """
  Upserts a resolver object in `/dns/configuration` `nameservers` with `useWithExitNode: true`,
  preserving all other nameservers and their settings.
  """
  def upsert_config_resolver(resolvers, dns_ip)
      when is_list(resolvers) and is_binary(dns_ip) and dns_ip != "" do
    normalized =
      Enum.reduce(resolvers, [], fn item, acc ->
        case normalize_config_resolver(item) do
          nil -> acc
          entry -> [entry | acc]
        end
      end)
      |> Enum.reverse()

    {updated, found?} =
      Enum.map_reduce(normalized, false, fn entry, seen ->
        if entry["address"] == dns_ip do
          {Map.put(entry, "useWithExitNode", true), true}
        else
          {entry, seen}
        end
      end)

    if found? do
      updated
    else
      updated ++ [%{"address" => dns_ip, "useWithExitNode" => true}]
    end
  end

  def upsert_config_resolver(resolvers, _), do: if(is_list(resolvers), do: resolvers, else: [])

  @doc """
  Removes a resolver entry matching `dns_ip` from `/dns/configuration` `nameservers`
  while preserving all other resolvers and their `useWithExitNode` flags.
  """
  def remove_config_resolver(resolvers, nil), do: if(is_list(resolvers), do: resolvers, else: [])

  def remove_config_resolver(resolvers, dns_ip)
      when is_list(resolvers) and is_binary(dns_ip) do
    resolvers
    |> Enum.map(&normalize_config_resolver/1)
    |> Enum.reject(fn entry -> is_nil(entry) or entry["address"] == dns_ip end)
  end

  def remove_config_resolver(resolvers, _), do: if(is_list(resolvers), do: resolvers, else: [])

  @fqdn_regex ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/
  @split_service_actions ["route_tunnel", "block", "bypass"]
  @split_rule_actions [
    "route_tunnel",
    "smart_route",
    "block",
    "bypass",
    "redirect",
    "forward_dns",
    "forward_proxy"
  ]

  @doc """
  Collects all domains managed by Hermit (Services, Custom Rules, and SNI Proxy routes)
  that must be sent to the Hermit DNS Endpoint when Tailscale Split DNS is enabled.
  """
  @spec collect_split_dns_domains(map() | nil, [String.t()] | nil) :: [String.t()]
  def collect_split_dns_domains(dns_config, extra_domains \\ nil) do
    service_domains =
      case Map.get(dns_config || %{}, :services) do
        services when is_map(services) ->
          Enum.flat_map(services, fn {svc_id, cfg} ->
            action = is_map(cfg) && (Map.get(cfg, "action") || Map.get(cfg, :action))

            if action in @split_service_actions do
              Hermit.Services.Catalog.domains_for_service(to_string(svc_id))
            else
              []
            end
          end)

        _ ->
          []
      end

    rule_domains =
      case Map.get(dns_config || %{}, :custom_rules) do
        rules when is_list(rules) ->
          Enum.flat_map(rules, fn rule ->
            action = is_map(rule) && (Map.get(rule, "action") || Map.get(rule, :action))
            domain = is_map(rule) && (Map.get(rule, "domain") || Map.get(rule, :domain))

            if action in @split_rule_actions and is_binary(domain) do
              String.split(domain, [",", "\n", "\r", " "], trim: true)
            else
              []
            end
          end)

        _ ->
          []
      end

    sni_domains =
      if is_list(extra_domains) do
        extra_domains
      else
        try do
          Hermit.Vpn.SniProxy.all_domains()
        rescue
          _ -> []
        end
      end

    domain_set =
      (service_domains ++ rule_domains ++ sni_domains)
      |> Enum.map(&normalize_split_domain/1)
      |> Enum.filter(&(is_binary(&1) and Regex.match?(@fqdn_regex, &1)))
      |> MapSet.new()

    domain_set
    |> Enum.reject(&has_parent_in_set?(&1, domain_set))
    |> Enum.sort()
  end

  defp normalize_split_domain(domain) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.downcase()
    |> String.trim_leading("*.")
    |> String.trim_leading(".")
    |> String.trim_trailing(".")
  end

  defp normalize_split_domain(_), do: nil

  defp has_parent_in_set?(domain, set) do
    case :binary.match(domain, ".") do
      {idx, _} ->
        parent = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)
        MapSet.member?(set, parent) or has_parent_in_set?(parent, set)

      :nomatch ->
        false
    end
  end

  defp resolve_tailscale_dns_mode(dns_config, inbound_profile) do
    inbound_mode =
      case inbound_profile do
        %{config: cfg} when is_map(cfg) ->
          Map.get(cfg, "tailscale_dns_mode") || Map.get(cfg, :tailscale_dns_mode)

        _ ->
          nil
      end

    if inbound_mode in ["split", "global"] do
      inbound_mode
    else
      (dns_config && Map.get(dns_config, :tailscale_dns_mode)) || "split"
    end
  end

  @doc """
  Builds the effective Tailscale DNS sync plan for a `DnsConfig` profile and
  optional `InboundProfile`.
  """
  @spec build_sync_plan(map() | nil, [String.t()] | nil, [String.t()], map() | nil) :: map()
  def build_sync_plan(
        dns_config,
        extra_domains \\ nil,
        extra_upstreams \\ [],
        inbound_profile \\ nil
      ) do
    mode = resolve_tailscale_dns_mode(dns_config, inbound_profile)

    if mode == "global" do
      %{
        mode: :global,
        fallback_reason: nil,
        upstream_resolvers: [],
        split_domains: [],
        strip_resolvers: build_global_strip_resolvers(dns_config, extra_upstreams)
      }
    else
      upstream = dns_config && Map.get(dns_config, :upstream_dns)

      case Hermit.Dns.Providers.tailscale_global_resolvers(upstream) do
        {:ok, resolvers} ->
          %{
            mode: :split,
            fallback_reason: nil,
            upstream_resolvers: resolvers,
            split_domains: collect_split_dns_domains(dns_config, extra_domains),
            strip_resolvers: []
          }

        {:fallback_global, reason} ->
          %{
            mode: :global,
            fallback_reason: reason,
            upstream_resolvers: [],
            split_domains: [],
            strip_resolvers: build_global_strip_resolvers(dns_config, extra_upstreams)
          }
      end
    end
  end

  defp build_global_strip_resolvers(dns_config, extra_upstreams) do
    upstream = dns_config && Map.get(dns_config, :upstream_dns)

    current_resolvers =
      case Hermit.Dns.Providers.tailscale_global_resolvers(upstream) do
        {:ok, list} -> list
        _ -> []
      end

    (current_resolvers ++
       Hermit.Dns.Providers.all_preset_global_resolvers() ++
       List.wrap(extra_upstreams))
    |> Enum.uniq()
  end

  defp build_clear_strip_resolvers(dns_config, extra_upstreams, inbound_profile) do
    mode = resolve_tailscale_dns_mode(dns_config, inbound_profile)
    upstream = dns_config && Map.get(dns_config, :upstream_dns)

    current_resolvers =
      if mode == "split" do
        case Hermit.Dns.Providers.tailscale_global_resolvers(upstream) do
          {:ok, list} -> list
          _ -> []
        end
      else
        []
      end

    (current_resolvers ++ List.wrap(extra_upstreams))
    |> Enum.uniq()
  end

  defp dns_sync_signature(config, inbound_profile) do
    if Map.get(config, :tailscale_override_dns) do
      plan = build_sync_plan(config, nil, [], inbound_profile)
      {:enabled, plan.mode, plan.upstream_resolvers, plan.split_domains}
    else
      :disabled
    end
  end

  @doc """
  Builds an updated `/dns/configuration` payload that registers `dns_ip` with
  `useWithExitNode: true` and enables `overrideLocalDNS: true`, strips any
  stale Split DNS `strip_resolvers` from `nameservers`, removes `dns_ip` from
  `splitDNS`, and preserves other fields (such as `searchPaths` and `magicDNS`).
  """
  def build_updated_dns_configuration(current_config, dns_ip, strip_resolvers \\ [])
      when is_map(current_config) and is_binary(dns_ip) and dns_ip != "" and
             is_list(strip_resolvers) do
    existing_nameservers =
      case Map.get(current_config, "nameservers") do
        list when is_list(list) -> list
        _ -> []
      end

    cleaned_nameservers =
      strip_resolvers
      |> Enum.reject(&(&1 == dns_ip))
      |> Enum.reduce(existing_nameservers, fn addr, acc ->
        remove_config_resolver(acc, addr)
      end)

    existing_prefs =
      case Map.get(current_config, "preferences") do
        prefs when is_map(prefs) -> prefs
        _ -> %{}
      end

    updated =
      current_config
      |> Map.put("nameservers", upsert_config_resolver(cleaned_nameservers, dns_ip))
      |> Map.put("preferences", Map.put(existing_prefs, "overrideLocalDNS", true))

    if is_map(Map.get(current_config, "splitDNS")) do
      Map.put(updated, "splitDNS", remove_split_dns_ip(current_config["splitDNS"], dns_ip))
    else
      updated
    end
  end

  @doc """
  Builds an updated `/dns/configuration` payload for Split DNS mode:
  sets global `nameservers` directly to `upstream_resolvers`, routes `split_domains`
  to `hermit_dns_ip`, removes stale `hermit_dns_ip` entries, and preserves other settings.
  """
  def build_split_dns_configuration(
        current_config,
        hermit_dns_ip,
        upstream_resolvers,
        split_domains
      )
      when is_map(current_config) and is_binary(hermit_dns_ip) and hermit_dns_ip != "" and
             is_list(upstream_resolvers) and is_list(split_domains) do
    existing_split_dns =
      case Map.get(current_config, "splitDNS") do
        split when is_map(split) -> split
        _ -> %{}
      end

    cleaned_split_dns = remove_split_dns_ip(existing_split_dns, hermit_dns_ip)

    updated_split_dns =
      Enum.reduce(split_domains, cleaned_split_dns, fn domain, acc ->
        existing_domain_resolvers = Map.get(acc, domain, [])
        Map.put(acc, domain, upsert_config_resolver(existing_domain_resolvers, hermit_dns_ip))
      end)

    nameservers =
      Enum.map(upstream_resolvers, fn addr ->
        %{"address" => addr, "useWithExitNode" => true}
      end)

    existing_prefs =
      case Map.get(current_config, "preferences") do
        prefs when is_map(prefs) -> prefs
        _ -> %{}
      end

    current_config
    |> Map.put("nameservers", nameservers)
    |> Map.put("splitDNS", updated_split_dns)
    |> Map.put("preferences", Map.put(existing_prefs, "overrideLocalDNS", true))
  end

  defp remove_split_dns_ip(split_dns, target_ip) when is_map(split_dns) do
    Enum.reduce(split_dns, %{}, fn {domain, resolvers}, acc ->
      remaining = remove_config_resolver(resolvers, target_ip)

      if Enum.empty?(remaining) do
        acc
      else
        Map.put(acc, domain, remaining)
      end
    end)
  end

  defp remove_split_dns_ip(_, _), do: %{}

  @doc """
  Builds an updated `/dns/configuration` payload that removes `target_ip` and any
  `strip_resolvers` from `nameservers` (plus `target_ip` from `splitDNS` when present)
  and disables `overrideLocalDNS` when no nameservers remain.
  """
  def build_cleared_dns_configuration(current_config, target_ip, strip_resolvers \\ [])
      when is_map(current_config) and is_binary(target_ip) and is_list(strip_resolvers) do
    existing_nameservers =
      case Map.get(current_config, "nameservers") do
        list when is_list(list) -> list
        _ -> []
      end

    remaining =
      [target_ip | strip_resolvers]
      |> Enum.uniq()
      |> Enum.reduce(existing_nameservers, fn addr, acc ->
        remove_config_resolver(acc, addr)
      end)

    existing_prefs =
      case Map.get(current_config, "preferences") do
        prefs when is_map(prefs) -> prefs
        _ -> %{}
      end

    updated_prefs =
      if Enum.empty?(remaining) do
        Map.put(existing_prefs, "overrideLocalDNS", false)
      else
        existing_prefs
      end

    cleared =
      current_config
      |> Map.put("nameservers", remaining)
      |> Map.put("preferences", updated_prefs)

    if is_map(Map.get(current_config, "splitDNS")) do
      Map.put(cleared, "splitDNS", remove_split_dns_ip(current_config["splitDNS"], target_ip))
    else
      cleared
    end
  end

  defp normalize_config_resolver(%{"address" => addr} = map)
       when is_binary(addr) and addr != "" do
    map
  end

  defp normalize_config_resolver(%{address: addr} = map) when is_binary(addr) and addr != "" do
    map
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_config_resolver(%{"addr" => addr} = map) when is_binary(addr) and addr != "" do
    map
    |> Map.delete("addr")
    |> Map.put("address", addr)
  end

  defp normalize_config_resolver(%{addr: addr} = map) when is_binary(addr) and addr != "" do
    map
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.delete("addr")
    |> Map.put("address", addr)
  end

  defp normalize_config_resolver(addr) when is_binary(addr) and addr != "" do
    %{"address" => addr}
  end

  defp normalize_config_resolver(_), do: nil

  def update_tailscale_dns_config(dns_ip, profile, dns_config, extra_upstreams \\ [])

  def update_tailscale_dns_config(_dns_ip, profile, _dns_config, _extra_upstreams)
      when is_nil(profile) do
    {:ok, :noop}
  end

  def update_tailscale_dns_config(dns_ip, profile, dns_config, extra_upstreams) do
    plan = build_sync_plan(dns_config, nil, extra_upstreams, profile)

    cond do
      mock?() ->
        if plan.mode == :split do
          Logger.info(
            "Mock: Syncing Tailscale Split DNS (Global: #{Enum.join(plan.upstream_resolvers, ", ")}, #{length(plan.split_domains)} split domains -> #{dns_ip})"
          )
        else
          Logger.info(
            "Mock: Registering Tailscale global nameserver to Dedicated DNS IP: #{dns_ip}"
          )
        end

        {:ok, :updated}

      true ->
        {auth_key, tailnet, _login} = get_dns_credentials(profile)

        with {:ok, token} <- Hermit.Vpn.Inbound.Tailscale.get_api_token(auth_key),
             true <- is_binary(dns_ip) and dns_ip != "" do
          sync_tailscale_dns_via_api(dns_ip, tailnet, token, plan: plan)
        else
          {:error, reason} ->
            Logger.warning("Cannot update Tailscale DNS config: #{inspect(reason)}")
            {:error, reason}

          false ->
            Logger.warning("Cannot update Tailscale DNS config: DNS IP is empty or invalid")
            {:error, :empty_dns_ip}
        end
    end
  end

  @doc false
  def sync_tailscale_dns_via_api(dns_ip, tailnet, token, opts \\ []) do
    plan =
      Keyword.get(opts, :plan, %{
        mode: :global,
        fallback_reason: nil,
        upstream_resolvers: [],
        split_domains: [],
        strip_resolvers: []
      })

    req_opts = Keyword.delete(opts, :plan)

    if plan.mode == :split do
      Logger.info(
        "Syncing Tailscale Split DNS (Global: #{Enum.join(plan.upstream_resolvers, ", ")}, #{length(plan.split_domains)} domains -> #{dns_ip}, tailnet: #{tailnet})..."
      )
    else
      fallback_note =
        if plan.fallback_reason,
          do: " (fallback: #{plan.fallback_reason})",
          else: ""

      Logger.info(
        "Registering #{dns_ip} into Tailscale global nameservers with useWithExitNode=true#{fallback_note} (tailnet: #{tailnet})..."
      )
    end

    headers = [{"authorization", "Bearer #{token}"}]
    config_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/configuration"

    case Req.get(config_url, Keyword.merge([headers: headers], req_opts)) do
      {:ok, %{status: 200, body: current_config}} when is_map(current_config) ->
        updated_config =
          if plan.mode == :split do
            build_split_dns_configuration(
              current_config,
              dns_ip,
              plan.upstream_resolvers,
              plan.split_domains
            )
          else
            build_updated_dns_configuration(
              current_config,
              dns_ip,
              Map.get(plan, :strip_resolvers, [])
            )
          end

        case Req.post(
               config_url,
               Keyword.merge([json: updated_config, headers: headers], req_opts)
             ) do
          {:ok, %{status: 200}} ->
            Logger.info(
              "Successfully synced Tailscale DNS via /dns/configuration (mode: #{plan.mode}, node: #{dns_ip})."
            )

            {:ok, :updated}

          {:ok, %{status: 403, body: body}} ->
            Logger.error(
              "Failed to update Tailscale DNS configuration (HTTP 403 Forbidden): #{inspect(body)}. Please ensure your Tailscale OAuth Client has the 'dns' scope (read/write) enabled in Tailscale Admin Console."
            )

            {:error, {:http_error, 403, body}}

          other ->
            Logger.warning(
              "Tailscale /dns/configuration POST returned #{inspect(other)}; falling back to legacy DNS API."
            )

            sync_tailscale_legacy_for_plan(dns_ip, plan, tailnet, headers, req_opts)
        end

      {:ok, %{status: 403, body: body}} ->
        Logger.error(
          "Failed to read Tailscale DNS configuration (HTTP 403 Forbidden): #{inspect(body)}. Please ensure your Tailscale OAuth Client has the 'dns' scope (read/write) enabled in Tailscale Admin Console."
        )

        {:error, {:http_error, 403, body}}

      other ->
        Logger.warning(
          "Tailscale /dns/configuration GET unavailable (#{inspect(other)}); falling back to legacy DNS API."
        )

        sync_tailscale_legacy_for_plan(dns_ip, plan, tailnet, headers, req_opts)
    end
  end

  defp sync_tailscale_legacy_for_plan(dns_ip, %{mode: :split} = plan, tailnet, headers, req_opts) do
    sync_tailscale_split_dns_legacy(dns_ip, plan, tailnet, headers, req_opts)
  end

  defp sync_tailscale_legacy_for_plan(dns_ip, plan, tailnet, headers, req_opts) do
    sync_tailscale_dns_legacy(
      dns_ip,
      tailnet,
      headers,
      req_opts,
      Map.get(plan, :strip_resolvers, [])
    )
  end

  defp sync_tailscale_split_dns_legacy(dns_ip, plan, tailnet, headers, req_opts) do
    dns_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/nameservers"
    split_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/split-dns"

    case Req.post(
           dns_url,
           Keyword.merge([json: %{"dns" => plan.upstream_resolvers}, headers: headers], req_opts)
         ) do
      {:ok, %{status: 200}} ->
        prefs_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/preferences"

        _ =
          Req.post(
            prefs_url,
            Keyword.merge([json: %{"overrideLocalDNS" => true}, headers: headers], req_opts)
          )

        current_split =
          case Req.get(split_url, Keyword.merge([headers: headers], req_opts)) do
            {:ok, %{status: 200, body: body}} when is_map(body) -> body
            _ -> %{}
          end

        cleaned_split =
          Enum.reduce(current_split, %{}, fn {domain, resolvers}, acc ->
            remaining =
              if is_list(resolvers), do: remove_resolver(resolvers, dns_ip), else: []

            if Enum.empty?(remaining), do: acc, else: Map.put(acc, domain, remaining)
          end)

        updated_split =
          Enum.reduce(plan.split_domains, cleaned_split, fn domain, acc ->
            existing = Map.get(acc, domain, [])
            Map.put(acc, domain, append_resolver(existing, dns_ip))
          end)

        case Req.put(split_url, Keyword.merge([json: updated_split, headers: headers], req_opts)) do
          {:ok, %{status: 200}} ->
            Logger.info("Successfully synced Tailscale Split DNS via legacy API.")
            {:ok, :updated}

          {:ok, %{status: 403, body: body}} ->
            Logger.error(
              "Failed to update Tailscale Split DNS (HTTP 403 Forbidden): #{inspect(body)}."
            )

            {:error, {:http_error, 403, body}}

          {:ok, %{status: status, body: body}} ->
            Logger.error(
              "Failed to update Tailscale Split DNS (HTTP #{status}): #{inspect(body)}"
            )

            {:error, {:http_error, status, body}}

          {:error, reason} ->
            Logger.error("Failed calling Tailscale Split DNS API: #{inspect(reason)}")
            {:error, reason}
        end

      {:ok, %{status: 403, body: body}} ->
        Logger.error(
          "Failed to update Tailscale nameservers for Split DNS (HTTP 403 Forbidden): #{inspect(body)}."
        )

        {:error, {:http_error, 403, body}}

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "Failed to update Tailscale nameservers for Split DNS (HTTP #{status}): #{inspect(body)}"
        )

        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error(
          "Failed calling Tailscale DNS nameservers API for Split DNS: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp sync_tailscale_dns_legacy(dns_ip, tailnet, headers, req_opts, strip_resolvers) do
    dns_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/nameservers"

    current_resolvers =
      case Req.get(dns_url, Keyword.merge([headers: headers], req_opts)) do
        {:ok, %{status: 200, body: %{"dns" => resolvers}}} when is_list(resolvers) ->
          resolvers

        _ ->
          []
      end

    cleaned_resolvers =
      strip_resolvers
      |> Enum.reject(&(&1 == dns_ip))
      |> Enum.reduce(current_resolvers, fn addr, acc -> remove_resolver(acc, addr) end)

    new_resolvers = append_resolver(cleaned_resolvers, dns_ip)
    payload = %{"dns" => new_resolvers}

    case Req.post(dns_url, Keyword.merge([json: payload, headers: headers], req_opts)) do
      {:ok, %{status: 200}} ->
        prefs_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/preferences"

        _ =
          Req.post(
            prefs_url,
            Keyword.merge([json: %{"overrideLocalDNS" => true}, headers: headers], req_opts)
          )

        Logger.info("Successfully registered Dedicated DNS Node (#{dns_ip}) on Tailscale.")
        {:ok, :updated}

      {:ok, %{status: 403, body: body}} ->
        Logger.error(
          "Failed to update Tailscale nameservers (HTTP 403 Forbidden): #{inspect(body)}. Please ensure your Tailscale OAuth Client has the 'dns' scope (read/write) enabled in Tailscale Admin Console."
        )

        {:error, {:http_error, 403, body}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to update Tailscale nameservers (HTTP #{status}): #{inspect(body)}")

        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("Failed calling Tailscale DNS nameservers API: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def clear_tailscale_dns_config(dns_config) do
    endpoint_id = dns_config && dns_config.dns_endpoint_id
    endpoint = if endpoint_id, do: Hermit.Repo.get(Hermit.Vpn.DnsEndpoint, endpoint_id)
    profile_id = endpoint && endpoint.inbound_profile_id
    profile = if profile_id, do: Hermit.Repo.get(Hermit.Vpn.InboundProfile, profile_id)
    clear_tailscale_dns_config(profile, dns_config, nil, [])
  end

  def clear_tailscale_dns_config(profile, dns_config) do
    clear_tailscale_dns_config(profile, dns_config, nil, [])
  end

  def clear_tailscale_dns_config(profile, dns_config, dns_ip, extra_upstreams \\ [])

  def clear_tailscale_dns_config(profile, _dns_config, _dns_ip, _extra_upstreams)
      when is_nil(profile) do
    {:ok, :noop}
  end

  def clear_tailscale_dns_config(profile, dns_config, dns_ip, extra_upstreams) do
    strip_resolvers = build_clear_strip_resolvers(dns_config, extra_upstreams, profile)

    cond do
      mock?() ->
        Logger.info("Mock: Removing #{inspect(dns_ip)} from Tailscale global nameservers")
        {:ok, :cleared}

      true ->
        {auth_key, tailnet, _login} = get_dns_credentials(profile)

        case Hermit.Vpn.Inbound.Tailscale.get_api_token(auth_key) do
          {:ok, token} ->
            target_ip = dns_ip || resolve_endpoint_tailscale_ip(dns_config, token, tailnet)

            if target_ip && target_ip != "" do
              clear_tailscale_dns_via_api(target_ip, tailnet, token,
                strip_resolvers: strip_resolvers
              )
            else
              Logger.info(
                "No active Tailscale IP resolved for endpoint, skipping DNS deregistration."
              )

              {:ok, :noop}
            end

          {:error, reason} ->
            Logger.warning("Cannot clear Tailscale DNS config: #{inspect(reason)}")
            {:ok, :noop}
        end
    end
  end

  @doc false
  def clear_tailscale_dns_via_api(target_ip, tailnet, token, opts \\ []) do
    strip_resolvers = Keyword.get(opts, :strip_resolvers, [])
    req_opts = Keyword.delete(opts, :strip_resolvers)

    Logger.info(
      "Deregistering #{target_ip} from Tailscale global nameservers (tailnet: #{tailnet})..."
    )

    headers = [{"authorization", "Bearer #{token}"}]
    config_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/configuration"

    case Req.get(config_url, Keyword.merge([headers: headers], req_opts)) do
      {:ok, %{status: 200, body: current_config}} when is_map(current_config) ->
        updated_config =
          build_cleared_dns_configuration(current_config, target_ip, strip_resolvers)

        case Req.post(
               config_url,
               Keyword.merge([json: updated_config, headers: headers], req_opts)
             ) do
          {:ok, %{status: 200}} ->
            Logger.info(
              "Successfully deregistered DNS Node (#{target_ip}) from Tailscale via /dns/configuration."
            )

            {:ok, :cleared}

          {:ok, %{status: 403, body: body}} ->
            Logger.error(
              "Failed to update Tailscale DNS configuration (HTTP 403 Forbidden): #{inspect(body)}. Please ensure your Tailscale OAuth Client has the 'dns' scope (read/write) enabled in Tailscale Admin Console."
            )

            {:error, {:http_error, 403, body}}

          other ->
            Logger.warning(
              "Tailscale /dns/configuration POST returned #{inspect(other)}; falling back to legacy /dns/nameservers API."
            )

            clear_tailscale_dns_legacy(target_ip, tailnet, headers, req_opts, strip_resolvers)
        end

      {:ok, %{status: 403, body: body}} ->
        Logger.error(
          "Failed to read Tailscale DNS configuration (HTTP 403 Forbidden): #{inspect(body)}. Please ensure your Tailscale OAuth Client has the 'dns' scope (read/write) enabled in Tailscale Admin Console."
        )

        {:error, {:http_error, 403, body}}

      other ->
        Logger.warning(
          "Tailscale /dns/configuration GET unavailable (#{inspect(other)}); falling back to legacy /dns/nameservers API."
        )

        clear_tailscale_dns_legacy(target_ip, tailnet, headers, req_opts, strip_resolvers)
    end
  end

  defp clear_tailscale_dns_legacy(
         target_ip,
         tailnet,
         headers,
         req_opts,
         strip_resolvers
       ) do
    dns_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/nameservers"

    current_resolvers =
      case Req.get(dns_url, Keyword.merge([headers: headers], req_opts)) do
        {:ok, %{status: 200, body: %{"dns" => resolvers}}} when is_list(resolvers) ->
          resolvers

        _ ->
          []
      end

    remaining_resolvers =
      [target_ip | strip_resolvers]
      |> Enum.uniq()
      |> Enum.reduce(current_resolvers, fn addr, acc -> remove_resolver(acc, addr) end)

    payload = %{"dns" => remaining_resolvers}

    case Req.post(dns_url, Keyword.merge([json: payload, headers: headers], req_opts)) do
      {:ok, %{status: 200}} ->
        if Enum.empty?(remaining_resolvers) do
          prefs_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/preferences"

          _ =
            Req.post(
              prefs_url,
              Keyword.merge([json: %{"overrideLocalDNS" => false}, headers: headers], req_opts)
            )
        end

        Logger.info("Successfully deregistered DNS Node (#{target_ip}) from Tailscale.")
        {:ok, :cleared}

      {:ok, %{status: 403, body: body}} ->
        Logger.error(
          "Failed to update Tailscale nameservers (HTTP 403 Forbidden): #{inspect(body)}. Please ensure your Tailscale OAuth Client has the 'dns' scope (read/write) enabled in Tailscale Admin Console."
        )

        {:error, {:http_error, 403, body}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to update Tailscale nameservers (HTTP #{status}): #{inspect(body)}")

        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("Failed calling Tailscale DNS nameservers API: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_endpoint_tailscale_ip(dns_config, token, tailnet) do
    endpoint_id = dns_config && dns_config.dns_endpoint_id

    if endpoint_id do
      case get_status(endpoint_id) do
        {_, ip, _} when is_binary(ip) and ip != "" ->
          ip

        _ ->
          expected_hostname = "hermit-dns-#{endpoint_id}"
          devices_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/devices"

          case Req.get(devices_url, headers: [{"authorization", "Bearer #{token}"}]) do
            {:ok, %{status: 200, body: %{"devices" => devices}}} when is_list(devices) ->
              device =
                Enum.find(devices, fn dev ->
                  dev["hostname"] == expected_hostname or
                    String.starts_with?(dev["name"] || "", expected_hostname <> ".")
                end)

              if device do
                addresses = device["addresses"] || []

                Enum.find(addresses, fn addr ->
                  case :inet.parse_address(String.to_charlist(addr)) do
                    {:ok, {100, _, _, _}} -> true
                    _ -> false
                  end
                end)
              else
                nil
              end

            _ ->
              nil
          end
      end
    else
      nil
    end
  end

  # --- Helpers ---

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    mock_env? = Code.ensure_loaded?(Mix) and Mix.env() == :test
    Keyword.get(config, :mock, false) or System.get_env("MOCK_VPN") == "true" or mock_env?
  end

  defp get_storage_base_path do
    config = Application.get_env(:hermit, :storage, [])
    Keyword.get(config, :base_path, "/app/storage")
  end

  defp build_resolv_conf(resolv_content) do
    lines = String.split(resolv_content, "\n")

    # Extract non-loopback nameservers from host resolv.conf
    host_nameservers =
      Enum.filter(lines, fn line ->
        trimmed = String.trim(line)

        if String.starts_with?(trimmed, "nameserver ") do
          ip = String.replace(trimmed, "nameserver ", "") |> String.trim()
          # Exclude loopback (127.*), link-local (169.254.*), and tailscale IP
          not String.starts_with?(ip, "127.") and
            not String.starts_with?(ip, "169.254.") and
            not String.contains?(ip, "100.100.100.100")
        else
          false
        end
      end)
      # Format back to nameserver lines
      |> Enum.map(&String.trim/1)

    # Standard public fallbacks
    fallbacks = ["nameserver 1.1.1.1", "nameserver 8.8.8.8"]

    # Combine them (host upstreams first, then fallbacks, then search/options lines)
    other_lines =
      Enum.reject(lines, fn line ->
        trimmed = String.trim(line)
        String.starts_with?(trimmed, "nameserver ")
      end)

    (host_nameservers ++ fallbacks ++ other_lines)
    |> Enum.join("\n")
  end

  defp setup_dns_nftables(ns, host_ip, port, storage_dir, host_ts_ip) do
    sni_http_port = Hermit.Vpn.SniProxy.Server.http_port()
    sni_https_port = Hermit.Vpn.SniProxy.Server.https_port()

    host_ts_masquerade =
      if is_binary(host_ts_ip) and host_ts_ip != "" do
        "add rule ip hermit_ns postrouting ip saddr #{host_ts_ip} oifname \"eth0\" masquerade"
      else
        ""
      end

    script = """
    add table ip hermit_ns
    flush table ip hermit_ns
    add chain ip hermit_ns prerouting { type nat hook prerouting priority dstnat ; }
    add chain ip hermit_ns forward { type filter hook forward priority filter ; }
    add chain ip hermit_ns postrouting { type nat hook postrouting priority srcnat - 10 ; }
    add rule ip hermit_ns prerouting udp dport 53 dnat to #{host_ip}:#{port}
    add rule ip hermit_ns prerouting tcp dport 53 dnat to #{host_ip}:#{port}
    add rule ip hermit_ns prerouting tcp dport 80 dnat to #{host_ip}:#{sni_http_port}
    add rule ip hermit_ns prerouting tcp dport 443 dnat to #{host_ip}:#{sni_https_port}
    add rule ip hermit_ns forward accept
    #{host_ts_masquerade}
    """

    nft_path = Path.join(storage_dir, "nftables.conf")

    try do
      File.write!(nft_path, script)

      case run_cmd("ip", ["netns", "exec", ns, "nft", "-f", nft_path]) do
        {:ok, out} ->
          {:ok, out}

        {:error, _} ->
          fallback_dns_nftables(ns, host_ip, port, host_ts_ip)
      end
    rescue
      _ ->
        fallback_dns_nftables(ns, host_ip, port, host_ts_ip)
    end
  end

  defp fallback_dns_nftables(ns, host_ip, port, host_ts_ip) do
    sni_http_port = Hermit.Vpn.SniProxy.Server.http_port()
    sni_https_port = Hermit.Vpn.SniProxy.Server.https_port()

    with {:ok, _} <-
           run_cmd("ip", ["netns", "exec", ns, "nft", "add", "table", "ip", "hermit_ns"]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             ns,
             "nft",
             "add",
             "chain",
             "ip",
             "hermit_ns",
             "prerouting",
             "{ type nat hook prerouting priority dstnat ; }"
           ]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             ns,
             "nft",
             "add",
             "chain",
             "ip",
             "hermit_ns",
             "forward",
             "{ type filter hook forward priority filter ; }"
           ]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             ns,
             "nft",
             "add",
             "chain",
             "ip",
             "hermit_ns",
             "postrouting",
             "{ type nat hook postrouting priority srcnat - 10 ; }"
           ]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             ns,
             "nft",
             "add",
             "rule",
             "ip",
             "hermit_ns",
             "prerouting",
             "udp",
             "dport",
             "53",
             "dnat",
             "to",
             "#{host_ip}:#{port}"
           ]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             ns,
             "nft",
             "add",
             "rule",
             "ip",
             "hermit_ns",
             "prerouting",
             "tcp",
             "dport",
             "53",
             "dnat",
             "to",
             "#{host_ip}:#{port}"
           ]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             ns,
             "nft",
             "add",
             "rule",
             "ip",
             "hermit_ns",
             "prerouting",
             "tcp",
             "dport",
             "80",
             "dnat",
             "to",
             "#{host_ip}:#{sni_http_port}"
           ]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             ns,
             "nft",
             "add",
             "rule",
             "ip",
             "hermit_ns",
             "prerouting",
             "tcp",
             "dport",
             "443",
             "dnat",
             "to",
             "#{host_ip}:#{sni_https_port}"
           ]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             ns,
             "nft",
             "add",
             "rule",
             "ip",
             "hermit_ns",
             "forward",
             "accept"
           ]) do
      if is_binary(host_ts_ip) and host_ts_ip != "" do
        run_cmd("ip", [
          "netns",
          "exec",
          ns,
          "nft",
          "add",
          "rule",
          "ip",
          "hermit_ns",
          "postrouting",
          "ip",
          "saddr",
          host_ts_ip,
          "oifname",
          "eth0",
          "masquerade"
        ])
      else
        {:ok, ""}
      end
    end
  end

  defp run_cmd(cmd, args) do
    if mock?() do
      {:ok, ""}
    else
      flat_args = List.flatten(args)
      Logger.debug("Running: #{cmd} #{Enum.join(flat_args, " ")}")

      try do
        case System.cmd(cmd, flat_args, stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, String.trim(output)}

          {output, code} ->
            Logger.error(
              "Command failed: #{cmd} #{Enum.join(flat_args, " ")} (exit code #{code}): #{output}"
            )

            {:error, {code, String.trim(output)}}
        end
      rescue
        e ->
          Logger.warning("Command #{cmd} failed with exception: #{inspect(e)}")
          {:error, e}
      end
    end
  end

  defp netns_exists?(ns_name) do
    if mock?() do
      false
    else
      try do
        case System.cmd("ip", ["netns", "list"], stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.split("\n")
            |> Enum.any?(fn line -> String.starts_with?(line, ns_name) end)

          _ ->
            false
        end
      rescue
        _ -> false
      end
    end
  end

  defp netns_usable?(ns_name) do
    if mock?() do
      false
    else
      try do
        case System.cmd("ip", ["netns", "exec", ns_name, "true"]) do
          {_, 0} -> true
          _ -> false
        end
      rescue
        _ -> false
      end
    end
  end

  defp stop_tailscaled_by_pid(pid_path) do
    if File.exists?(pid_path) do
      case File.read(pid_path) do
        {:ok, pid_str} ->
          pid = String.trim(pid_str)

          try do
            case System.cmd("kill", [pid], stderr_to_stdout: true) do
              {_, 0} ->
                Process.sleep(200)

                case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
                  {_, 0} -> System.cmd("kill", ["-9", pid], stderr_to_stdout: true)
                  _ -> :ok
                end

              _ ->
                :ok
            end
          rescue
            e ->
              Logger.warning("Failed to kill tailscaled process with PID #{pid}: #{inspect(e)}")
          end

        _ ->
          :ok
      end
    end
  end

  defp wait_for_socket(path, retries \\ 30)
  defp wait_for_socket(_path, 0), do: :ok

  defp wait_for_socket(path, retries) do
    if File.exists?(path) and socket_connectable?(path) do
      :ok
    else
      Process.sleep(200)
      wait_for_socket(path, retries - 1)
    end
  end

  defp socket_connectable?(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  # Mock Log Generation Helper
  defp send_mock_query(endpoint_id) do
    domains = [
      "google.com",
      "github.com",
      "doubleclick.net",
      "pornhub.com",
      "elixir-lang.org",
      "wikipedia.org",
      "netflix.com",
      "mixpanel.com"
    ]

    domain = Enum.random(domains)

    qname =
      domain
      |> String.split(".")
      |> Enum.map(fn label -> <<byte_size(label)>> <> label end)
      |> Enum.join()

    qname = qname <> <<0>>

    packet =
      <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
        qname <> <<0x00, 0x01, 0x00, 0x01>>

    port = 5400 + endpoint_id

    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        :gen_udp.send(socket, {127, 0, 0, 1}, port, packet)
        :gen_udp.close(socket)

      _ ->
        :ok
    end
  end

  defp wait_for_dns_resolve(ns, hosts, retries \\ 30)
  defp wait_for_dns_resolve(_ns, _hosts, 0), do: :ok

  defp wait_for_dns_resolve(ns, hosts, retries) do
    resolved? =
      Enum.any?(hosts, fn host ->
        case System.cmd("ip", ["netns", "exec", ns, "getent", "hosts", host]) do
          {_, 0} -> true
          _ -> false
        end
      end)

    if resolved? do
      Logger.info("DNS resolution is ready inside namespace #{ns}")
      :ok
    else
      Process.sleep(500)
      wait_for_dns_resolve(ns, hosts, retries - 1)
    end
  end
end
