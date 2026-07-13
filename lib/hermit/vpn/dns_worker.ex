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
            tailscale_override_dns: false

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

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    endpoint_id = opts[:endpoint_id]
    inbound_profile_id = opts[:inbound_profile_id]
    # Perform initial sync on startup
    send(self(), :initial_sync)
    {:ok, %__MODULE__{endpoint_id: endpoint_id, inbound_profile_id: inbound_profile_id}}
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
  def handle_info(:initial_sync, state) do
    {_, new_state} = do_sync_state(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:dns_node_start_result, result}, state) do
    if state.status == :starting do
      case result do
        {:ok, ip, port} ->
          # Get current config to check if override is enabled
          config = Hermit.Vpn.DnsConfig.get_for_endpoint(state.endpoint_id)

          profile =
            if state.inbound_profile_id,
              do: Hermit.Repo.get(Hermit.Vpn.InboundProfile, state.inbound_profile_id)

          mock_timer =
            if mock?() do
              Process.send_after(self(), :generate_mock_log, 1000)
            else
              nil
            end

          new_state = %{
            state
            | status: :running,
              ts_ip: ip,
              ts_port: port,
              error_reason: nil,
              mock_timer: mock_timer,
              tailscale_override_dns: config.tailscale_override_dns
          }

          if config.tailscale_override_dns and profile do
            spawn(fn -> update_tailscale_dns_config(ip, profile, config) end)
          end

          {:noreply, new_state}

        {:error, reason} ->
          {:noreply, %{state | status: :error, error_reason: inspect(reason)}}
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

      {:noreply,
       %{state | status: :error, error_reason: "Daemon exited: #{inspect(reason)}", ts_port: nil}}
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

      if config && profile do
        Task.start(fn -> clear_tailscale_dns_config(profile, config) end)
      end
    end

    stop_dns_node(state)
  end

  # --- Internal Lifecycle Management ---

  defp do_sync_state(state) do
    profile =
      if state.inbound_profile_id,
        do: Hermit.Repo.get(Hermit.Vpn.InboundProfile, state.inbound_profile_id)

    config = Hermit.Vpn.DnsConfig.get_for_endpoint(state.endpoint_id)
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

        new_state = stop_dns_node(state)

        if (config.tailscale_override_dns or state.tailscale_override_dns == true) and profile do
          spawn(fn -> clear_tailscale_dns_config(profile, config) end)
        end

        {{:ok, :stopped}, %{new_state | tailscale_override_dns: false}}

      endpoint.enabled and state.status == :running ->
        if state.tailscale_override_dns != config.tailscale_override_dns do
          if config.tailscale_override_dns and profile do
            spawn(fn -> update_tailscale_dns_config(state.ts_ip, profile, config) end)
          else
            if profile do
              spawn(fn -> clear_tailscale_dns_config(profile, config) end)
            end
          end

          {{:ok, :updated_dns_integration},
           %{
             state
             | tailscale_override_dns: config.tailscale_override_dns and not is_nil(profile)
           }}
        else
          {{:ok, :already_synced}, state}
        end

      true ->
        {{:ok, :already_synced}, state}
    end
  end

  defp get_dns_credentials(profile) do
    profile_config = (profile && profile.config) || %{}

    auth_key = Map.get(profile_config, "ts_auth_key") || ""
    api_key = Map.get(profile_config, "ts_api_key") || ""
    tailnet = Map.get(profile_config, "ts_tailnet") || ""
    login_server = Map.get(profile_config, "login_server") || ""

    {auth_key, api_key, tailnet, login_server}
  end

  defp start_dns_node_async(endpoint_id, profile) do
    if mock?() do
      {:ok, "100.64.0.100", nil}
    else
      storage_dir = Path.join(get_storage_base_path(), "dns_#{endpoint_id}")
      File.mkdir_p!(storage_dir)

      {auth_key, _api_key, _tailnet, login_server} = get_dns_credentials(profile)

      if auth_key == "" do
        {:error, "Tailscale auth key not configured"}
      else
        case bootstrap_namespace(endpoint_id, storage_dir, auth_key, login_server) do
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

  defp bootstrap_namespace(endpoint_id, storage_dir, auth_key, login_server) do
    ns = "hermit_dns_endpoint_#{endpoint_id}"
    host_if = "dns_h_#{endpoint_id}"
    ns_if = "dns_n_#{endpoint_id}"
    table_id = 1000 + endpoint_id
    host_ip = "10.251.#{endpoint_id}.1"
    ns_ip = "10.251.#{endpoint_id}.2"
    subnet = "10.251.#{endpoint_id}.0/30"
    port = 5400 + endpoint_id

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

        with {:ok, _} <- run_cmd("ip", ["netns", "add", ns]),
             {:ok, _} <-
               run_cmd("ip", ["link", "add", host_if, "type", "veth", "peer", "name", ns_if]),
             {:ok, _} <- run_cmd("ip", ["link", "set", ns_if, "netns", ns]),
             {:ok, _} <-
               run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", ns_if, "name", "eth0"]),
             {:ok, _} <- run_cmd("ip", ["addr", "add", "#{host_ip}/30", "dev", host_if]),
             {:ok, _} <-
               run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "ip",
                 "addr",
                 "add",
                 "#{ns_ip}/30",
                 "dev",
                 "eth0"
               ]),
             {:ok, _} <- run_cmd("ip", ["link", "set", host_if, "up"]),
             {:ok, _} <- run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", "eth0", "up"]),
             {:ok, _} <- run_cmd("ip", ["link", "set", host_if, "mtu", "1400"]),
             {:ok, _} <-
               run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", "eth0", "mtu", "1400"]),
             {:ok, _} <- run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", "lo", "up"]),
             {:ok, _} <-
               run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "sysctl",
                 "-w",
                 "net.ipv4.ip_forward=1"
               ]),
             {:ok, _} <-
               run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "sysctl",
                 "-w",
                 "net.ipv6.conf.all.forwarding=1"
               ]),
             {:ok, _} <-
               run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "sysctl",
                 "-w",
                 "net.ipv4.conf.all.rp_filter=0"
               ]),
             {:ok, _} <-
               run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "sysctl",
                 "-w",
                 "net.ipv4.conf.default.rp_filter=0"
               ]),
             {:ok, _} <-
               run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "sysctl",
                 "-w",
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
             # NAT routing on Host via endpoint-specific nftables table
             {:ok, _} <-
               run_cmd("nft", ["add", "table", "ip", "hermit_dns_endpoint_#{endpoint_id}"]),
             {:ok, _} <-
               run_cmd("nft", [
                 "add",
                 "chain",
                 "ip",
                 "hermit_dns_endpoint_#{endpoint_id}",
                 "forward",
                 "{ type filter hook forward priority filter ; }"
               ]),
             {:ok, _} <-
               run_cmd("nft", [
                 "add",
                 "chain",
                 "ip",
                 "hermit_dns_endpoint_#{endpoint_id}",
                 "postrouting",
                 "{ type nat hook postrouting priority srcnat ; }"
               ]),
             {:ok, _} <-
               run_cmd("nft", [
                 "add",
                 "rule",
                 "ip",
                 "hermit_dns_endpoint_#{endpoint_id}",
                 "forward",
                 "ip",
                 "saddr",
                 subnet,
                 "accept"
               ]),
             {:ok, _} <-
               run_cmd("nft", [
                 "add",
                 "rule",
                 "ip",
                 "hermit_dns_endpoint_#{endpoint_id}",
                 "forward",
                 "ip",
                 "daddr",
                 subnet,
                 "accept"
               ]),
             {:ok, _} <-
               run_cmd("nft", [
                 "add",
                 "rule",
                 "ip",
                 "hermit_dns_endpoint_#{endpoint_id}",
                 "postrouting",
                 "ip",
                 "saddr",
                 subnet,
                 "masquerade"
               ]),
             # DNAT port redirection inside namespace using nftables
             {:ok, _} <-
               run_cmd("ip", [
                 "netns",
                 "exec",
                 ns,
                 "nft",
                 "add",
                 "table",
                 "ip",
                 "hermit_ns"
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
             # Allow forwarding inside the namespace (to bypass Tailscale filter drops)
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
               ]),

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

            port_args = [
              "netns",
              "exec",
              ns,
              "tailscaled",
              "--socket=#{socket_path}",
              "--state=#{state_path}",
              "--port=#{41640 + endpoint_id}",
              "--no-logs-no-support"
            ]

            try do
              p = Port.open({:spawn_executable, "/usr/bin/ip"}, [:binary, args: port_args])

              case Port.info(p, :os_pid) do
                {:os_pid, os_pid} -> File.write!(pid_path, "#{os_pid}")
                _ -> :ok
              end

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
    ns = "hermit_dns_endpoint_#{endpoint_id}"
    host_if = "dns_h_#{endpoint_id}"
    table_id = 1000 + endpoint_id
    host_ip = "10.251.#{endpoint_id}.1"

    try do
      System.cmd("ip", ["link", "delete", host_if])

      if netns_exists?(ns) do
        System.cmd("ip", ["netns", "del", ns])
      end

      # Clean up netns DNS config directory
      File.rm_rf("/etc/netns/#{ns}")

      System.cmd("ip", [
        "rule",
        "delete",
        "from",
        host_ip,
        "to",
        "100.64.0.0/10",
        "table",
        to_string(table_id)
      ])

      System.cmd("ip", [
        "route",
        "flush",
        "table",
        to_string(table_id)
      ])

      # Clean up nftables table for this endpoint on host
      System.cmd("nft", ["delete", "table", "ip", "hermit_dns_endpoint_#{endpoint_id}"])
    rescue
      e ->
        Logger.warning(
          "Error encountered during DNS namespace cleanup for endpoint #{endpoint_id}: #{inspect(e)}"
        )
    end

    :ok
  end

  # --- Tailscale DNS Config API Update ---

  def update_tailscale_dns_config(_dns_ip, profile, _dns_config) when is_nil(profile) do
    {:ok, :noop}
  end

  def update_tailscale_dns_config(dns_ip, profile, _dns_config) do
    cond do
      mock?() ->
        Logger.info("Mock: Setting Tailscale global nameserver to Dedicated DNS IP: #{dns_ip}")
        {:ok, :updated}

      true ->
        {_auth_key, api_key, tailnet, _login} = get_dns_credentials(profile)

        if api_key != "" and tailnet != "" and dns_ip != "" do
          Logger.info("Setting Tailscale global nameserver to Dedicated DNS IP: #{dns_ip}")
          dns_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/config"
          payload = %{"resolvers" => [%{"addr" => dns_ip}], "proxied" => true}

          case Req.post(dns_url, json: payload, auth: {:basic, "#{api_key}:"}) do
            {:ok, %{status: 200}} ->
              Logger.info("Successfully registered Dedicated DNS Node on Tailscale.")

            {:ok, %{status: status, body: body}} ->
              Logger.error(
                "Failed to update Tailscale nameservers (HTTP #{status}): #{inspect(body)}"
              )

            {:error, reason} ->
              Logger.error("Failed calling Tailscale DNS config API: #{inspect(reason)}")
          end
        end
    end
  end

  def clear_tailscale_dns_config(dns_config) do
    endpoint_id = dns_config.dns_endpoint_id
    endpoint = if endpoint_id, do: Hermit.Repo.get(Hermit.Vpn.DnsEndpoint, endpoint_id)
    profile_id = endpoint && endpoint.inbound_profile_id
    profile = if profile_id, do: Hermit.Repo.get(Hermit.Vpn.InboundProfile, profile_id)
    clear_tailscale_dns_config(profile, dns_config)
  end

  def clear_tailscale_dns_config(profile, _dns_config) when is_nil(profile) do
    {:ok, :noop}
  end

  def clear_tailscale_dns_config(profile, _dns_config) do
    cond do
      mock?() ->
        Logger.info("Mock: Clearing Tailscale global nameservers")
        {:ok, :cleared}

      true ->
        {_auth_key, api_key, tailnet, _login} = get_dns_credentials(profile)

        if api_key != "" and tailnet != "" do
          Logger.info("Clearing Tailscale global nameservers...")
          dns_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/config"
          payload = %{"resolvers" => [], "proxied" => false}

          case Req.post(dns_url, json: payload, auth: {:basic, "#{api_key}:"}) do
            {:ok, %{status: 200}} ->
              Logger.info("Successfully cleared Tailscale DNS configuration.")

            _ ->
              :ok
          end
        else
          {:ok, :noop}
        end
    end
  end

  # --- Helpers ---

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
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

  defp run_cmd(cmd, args) do
    flat_args = List.flatten(args)
    Logger.info("Running: #{cmd} #{Enum.join(flat_args, " ")}")

    case System.cmd(cmd, flat_args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, code} ->
        Logger.error(
          "Command failed: #{cmd} #{Enum.join(flat_args, " ")} (exit code #{code}): #{output}"
        )

        {:error, {code, String.trim(output)}}
    end
  end

  defp netns_exists?(ns_name) do
    case System.cmd("ip", ["netns", "list"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.any?(fn line -> String.starts_with?(line, ns_name) end)

      _ ->
        false
    end
  end

  defp netns_usable?(ns_name) do
    case System.cmd("ip", ["netns", "exec", ns_name, "true"]) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp stop_tailscaled_by_pid(pid_path) do
    if File.exists?(pid_path) do
      case File.read(pid_path) do
        {:ok, pid_str} ->
          pid = String.trim(pid_str)

          try do
            System.cmd("kill", [pid])
            Process.sleep(200)
            System.cmd("kill", ["-9", pid])
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
