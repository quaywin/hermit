defmodule Hermit.Vpn.DnsWorker do
  use GenServer
  require Logger

  # State:
  # - :status (:stopped | :starting | :running | :error)
  # - :error_reason (nil | string)
  # - :ts_ip (nil | string)
  # - :ts_port (nil | port/pid)
  # - :mock_timer (nil | timer)
  defstruct [
    status: :stopped,
    error_reason: nil,
    ts_ip: nil,
    ts_port: nil,
    mock_timer: nil
  ]

  @name __MODULE__

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def sync_state do
    GenServer.call(@name, :sync_state)
  end

  def get_status do
    GenServer.call(@name, :get_status)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    # Perform initial sync on startup
    send(self(), :initial_sync)
    {:ok, %__MODULE__{}}
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
  def handle_info(:generate_mock_log, state) do
    # Generate mock DNS query log to port 5453 in mock mode
    if mock?() and state.status == :running do
      spawn(fn ->
        send_mock_query()
      end)
    end
    # Reschedule
    timer = Process.send_after(self(), :generate_mock_log, 3000)
    {:noreply, %{state | mock_timer: timer}}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, state) do
    if port == state.ts_port do
      Logger.error("DNS Tailscale daemon process exited: #{inspect(reason)}")
      {:noreply, %{state | status: :error, error_reason: "Daemon exited: #{inspect(reason)}", ts_port: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    stop_dns_node(state)
  end

  # --- Internal Lifecycle Management ---

  defp do_sync_state(state) do
    config = Hermit.Vpn.DnsConfig.get_global()

    cond do
      config.enabled and state.status in [:stopped, :error] ->
        Logger.info("DNS Server is enabled globally. Bootstrapping Dedicated DNS Node...")
        case start_dns_node(state) do
          {:ok, new_state} ->
            # Call Tailscale API to set Nameserver if configured
            if config.tailscale_override_dns do
              Task.start(fn -> update_tailscale_dns_config(new_state.ts_ip) end)
            end
            {{:ok, :started}, new_state}

          {:error, reason} ->
            {{:error, reason}, %{state | status: :error, error_reason: to_string(reason)}}
        end

      not config.enabled and state.status in [:running, :starting, :error] ->
        Logger.info("DNS Server is disabled globally. Stopping Dedicated DNS Node...")
        new_state = stop_dns_node(state)
        # Clear Tailscale nameservers if configured
        if config.tailscale_override_dns do
          Task.start(fn -> clear_tailscale_dns_config() end)
        end
        {{:ok, :stopped}, new_state}

      true ->
        # Already in desired state
        {{:ok, :already_synced}, state}
    end
  end

  defp start_dns_node(state) do
    if mock?() do
      # Start mock DNS worker
      timer = Process.send_after(self(), :generate_mock_log, 1000)
      {:ok, %{state | status: :running, ts_ip: "100.64.0.100", mock_timer: timer}}
    else
      storage_dir = Path.join(get_storage_base_path(), "dns")
      File.mkdir_p!(storage_dir)

      # Read credentials
      auth_key = Hermit.Vpn.Setting.get_value("tailscale_auth_key", "")
      login_server = Hermit.Vpn.Setting.get_value("tailscale_login_server", "")

      if auth_key == "" do
        {:error, "Tailscale auth key not configured in settings"}
      else
        case bootstrap_namespace(storage_dir, auth_key, login_server) do
          {:ok, port, ip} ->
            {:ok, %{state | status: :running, ts_ip: ip, ts_port: port, error_reason: nil}}

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
      cleanup_namespace()
      if state.ts_port, do: stop_port_process(state.ts_port)
      %{state | status: :stopped, ts_ip: nil, ts_port: nil, error_reason: nil}
    end
  end

  # --- Namespace Setup & Linux Commands ---

  defp bootstrap_namespace(storage_dir, auth_key, login_server) do
    # Namespace: hermit_dns
    # IPs: host=10.200.254.1/30, namespace=10.200.254.2/30
    ns = "hermit_dns"
    host_if = "dns_host"
    ns_if = "dns_ns"

    cleanup_namespace()

    result =
      with {:ok, _} <- run_cmd("ip", ["netns", "add", ns]),
           {:ok, _} <- run_cmd("ip", ["link", "add", host_if, "type", "veth", "peer", "name", ns_if]),
           {:ok, _} <- run_cmd("ip", ["link", "set", ns_if, "netns", ns]),
           {:ok, _} <- run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", ns_if, "name", "eth0"]),
           {:ok, _} <- run_cmd("ip", ["addr", "add", "10.200.254.1/30", "dev", host_if]),
           {:ok, _} <- run_cmd("ip", ["netns", "exec", ns, "ip", "addr", "add", "10.200.254.2/30", "dev", "eth0"]),
           {:ok, _} <- run_cmd("ip", ["link", "set", host_if, "up"]),
           {:ok, _} <- run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", "eth0", "up"]),
           {:ok, _} <- run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", "lo", "up"]),
           {:ok, _} <- run_cmd("ip", ["netns", "exec", ns, "ip", "route", "add", "default", "via", "10.200.254.1", "dev", "eth0"]),
           # NAT routing on Host
           {:ok, _} <- run_cmd("iptables", ["-t", "nat", "-A", "POSTROUTING", "-s", "10.200.254.0/30", "-j", "MASQUERADE"]),
           {:ok, _} <- run_cmd("iptables", ["-A", "FORWARD", "-s", "10.200.254.0/30", "-j", "ACCEPT"]),
           {:ok, _} <- run_cmd("iptables", ["-A", "FORWARD", "-d", "10.200.254.0/30", "-m", "state", "--state", "ESTABLISHED,RELATED", "-j", "ACCEPT"]),
           # DNAT port redirection inside namespace
           {:ok, _} <- run_cmd("ip", ["netns", "exec", ns, "iptables", "-t", "nat", "-A", "PREROUTING", "-p", "udp", "--dport", "53", "-j", "DNAT", "--to-destination", "10.200.254.1:5453"]),
           {:ok, _} <- run_cmd("ip", ["netns", "exec", ns, "iptables", "-t", "nat", "-A", "PREROUTING", "-p", "tcp", "--dport", "53", "-j", "DNAT", "--to-destination", "10.200.254.1:5453"]),
           # Route Tailscale traffic from host to namespace
           {:ok, _} <- run_cmd("ip", ["route", "add", "100.64.0.0/10", "via", "10.200.254.2"]) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end

    case result do
      :ok ->
        socket_path = "/run/tailscaled.dns.socket"
        File.rm(socket_path)

        state_path = Path.join(storage_dir, "tailscaled.state")
        pid_path = Path.join(storage_dir, "tailscaled.pid")

        # Start tailscaled in namespace
        port_args = [
          "netns", "exec", ns,
          "tailscaled",
          "--socket=#{socket_path}",
          "--state=#{state_path}",
          "--port=41642",
          "--no-logs-no-support"
        ]

        try do
          port = Port.open({:spawn_executable, "/usr/bin/ip"}, [:binary, args: port_args])

          case Port.info(port, :os_pid) do
            {:os_pid, os_pid} -> File.write!(pid_path, "#{os_pid}")
            _ -> :ok
          end

          # Wait for socket
          wait_for_socket(socket_path)

          # Authenticate
          ts_up_args = [
            "netns", "exec", ns,
            "tailscale",
            "--socket=#{socket_path}",
            "up",
            "--authkey=#{auth_key}",
            "--accept-dns=true",
            "--accept-routes=false",
            "--hostname=hermit-dns",
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
              # Fetch Tailscale IP
              case System.cmd("ip", ["netns", "exec", ns, "tailscale", "--socket=#{socket_path}", "ip", "-4"]) do
                {ip_out, 0} ->
                  ip = String.trim(ip_out)
                  {:ok, port, ip}

                _ ->
                  {:error, "Failed to retrieve Tailscale IP"}
              end

            {:error, reason} ->
              stop_tailscaled_by_pid(pid_path)
              {:error, {:tailscale_up_failed, reason}}
          end
        rescue
          e -> {:error, {:spawn_failed, e}}
        end

      {:error, reason} ->
        cleanup_namespace()
        {:error, reason}
    end
  end

  defp cleanup_namespace do
    ns = "hermit_dns"
    host_if = "dns_host"

    # Delete interface (deletes namespace side automatically)
    System.cmd("ip", ["link", "delete", host_if])

    # Delete namespace
    if netns_exists?(ns) do
      System.cmd("ip", ["netns", "del", ns])
    end

    # Remove host route
    System.cmd("ip", ["route", "delete", "100.64.0.0/10", "via", "10.200.254.2"])

    # Remove iptables MASQUERADE & FORWARD rules
    System.cmd("iptables", ["-t", "nat", "-D", "POSTROUTING", "-s", "10.200.254.0/30", "-j", "MASQUERADE"])
    System.cmd("iptables", ["-D", "FORWARD", "-s", "10.200.254.0/30", "-j", "ACCEPT"])
    System.cmd("iptables", ["-D", "FORWARD", "-d", "10.200.254.0/30", "-m", "state", "--state", "ESTABLISHED,RELATED", "-j", "ACCEPT"])

    :ok
  end

  # --- Tailscale DNS Config API Update ---

  defp update_tailscale_dns_config(dns_ip) do
    api_key = Hermit.Vpn.Setting.get_value("tailscale_api_key", "")
    tailnet = Hermit.Vpn.Setting.get_value("tailscale_tailnet", "")

    if api_key != "" and tailnet != "" and dns_ip != "" do
      Logger.info("Setting Tailscale global nameserver to Dedicated DNS IP: #{dns_ip}")
      dns_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/dns/config"
      payload = %{"resolvers" => [%{"addr" => dns_ip}], "proxied" => true}

      case Req.post(dns_url, json: payload, auth: {:basic, "#{api_key}:"}) do
        {:ok, %{status: 200}} ->
          Logger.info("Successfully registered Dedicated DNS Node on Tailscale.")

        {:ok, %{status: status, body: body}} ->
          Logger.error("Failed to update Tailscale nameservers (HTTP #{status}): #{inspect(body)}")

        {:error, reason} ->
          Logger.error("Failed calling Tailscale DNS config API: #{inspect(reason)}")
      end
    end
  end

  defp clear_tailscale_dns_config do
    api_key = Hermit.Vpn.Setting.get_value("tailscale_api_key", "")
    tailnet = Hermit.Vpn.Setting.get_value("tailscale_tailnet", "")

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

  defp run_cmd(cmd, args) do
    flat_args = List.flatten(args)
    case System.cmd(cmd, flat_args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {code, String.trim(output)}}
    end
  end

  defp netns_exists?(ns_name) do
    case System.cmd("ip", ["netns", "list"]) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.any?(fn line -> String.starts_with?(line, ns_name) end)

      _ ->
        false
    end
  end

  defp stop_port_process(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp stop_tailscaled_by_pid(pid_path) do
    if File.exists?(pid_path) do
      case File.read(pid_path) do
        {:ok, pid_str} ->
          pid = String.trim(pid_str)
          System.cmd("kill", [pid])
          Process.sleep(200)
          System.cmd("kill", ["-9", pid])
        _ ->
          :ok
      end
    end
  end

  defp wait_for_socket(path, retries \\ 10)
  defp wait_for_socket(_path, 0), do: :ok
  defp wait_for_socket(path, retries) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(200)
      wait_for_socket(path, retries - 1)
    end
  end

  # Mock Log Generation Helper
  defp send_mock_query do
    domains = [
      "google.com", "github.com", "doubleclick.net", "pornhub.com",
      "elixir-lang.org", "wikipedia.org", "netflix.com", "mixpanel.com"
    ]
    domain = Enum.random(domains)
    # Simple DNS query packet: Transaction ID (0x1234), flags (0x0100 - recursion desired), Questions=1, Answer/Authority/Additional=0
    # Question: domain label sequence, type=A (0x0001), class=IN (0x0001)
    qname = domain
            |> String.split(".")
            |> Enum.map(fn label -> <<byte_size(label)>> <> label end)
            |> Enum.join()
    qname = qname <> <<0>>

    packet = <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <> qname <> <<0x00, 0x01, 0x00, 0x01>>
    
    # Open socket and send to localhost:5453
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        # Send from a simulated Tailscale client IP

        # Since we send UDP directly to 127.0.0.1:5453, we are acting as the client,
        # but to test DNS Server's parsing of client IP, it will see 127.0.0.1.
        # This is completely fine for mock logs verification!
        :gen_udp.send(socket, {127, 0, 0, 1}, 5453, packet)
        :gen_udp.close(socket)

      _ -> :ok
    end
  end
end
