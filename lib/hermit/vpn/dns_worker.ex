defmodule Hermit.Vpn.DnsWorker do
  use GenServer
  require Logger

  # State:
  # - :profile_id (integer)
  # - :status (:stopped | :starting | :running | :error)
  # - :error_reason (nil | string)
  # - :ts_ip (nil | string)
  # - :ts_port (nil | port/pid)
  # - :mock_timer (nil | timer)
  defstruct profile_id: nil,
            status: :stopped,
            error_reason: nil,
            ts_ip: nil,
            ts_port: nil,
            mock_timer: nil,
            tailscale_override_dns: false

  # --- Client API ---

  def start_link(opts) do
    profile_id = opts[:profile_id]
    name = {:via, Registry, {Hermit.Vpn.Registry, {:dns_worker, profile_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def sync_state(profile_id) do
    case Registry.lookup(Hermit.Vpn.Registry, {:dns_worker, profile_id}) do
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

  def get_status(profile_id) do
    case Registry.lookup(Hermit.Vpn.Registry, {:dns_worker, profile_id}) do
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
    profile_id = opts[:profile_id]
    # Perform initial sync on startup
    send(self(), :initial_sync)
    {:ok, %__MODULE__{profile_id: profile_id}}
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
    if mock?() and state.status == :running do
      spawn(fn ->
        send_mock_query(state.profile_id)
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
    stop_dns_node(state)
  end

  # --- Internal Lifecycle Management ---

  defp do_sync_state(state) do
    config =
      Hermit.Vpn.DnsConfig.get_for_profile(state.profile_id)
      |> Hermit.Repo.preload(:inbound_profile)

    cond do
      config.enabled and state.status in [:stopped, :error] ->
        Logger.info(
          "DNS Server is enabled for profile #{state.profile_id}. Bootstrapping Dedicated DNS Node..."
        )

        case start_dns_node(state, config) do
          {:ok, new_state} ->
            if config.tailscale_override_dns do
              Task.start(fn -> update_tailscale_dns_config(new_state.ts_ip, config) end)
            end

            {{:ok, :started},
             %{new_state | tailscale_override_dns: config.tailscale_override_dns}}

          {:error, reason} ->
            {{:error, reason}, %{state | status: :error, error_reason: inspect(reason)}}
        end

      not config.enabled and state.status in [:running, :starting, :error] ->
        Logger.info(
          "DNS Server is disabled for profile #{state.profile_id}. Stopping Dedicated DNS Node..."
        )

        new_state = stop_dns_node(state)

        if config.tailscale_override_dns or state.tailscale_override_dns == true do
          Task.start(fn -> clear_tailscale_dns_config(config) end)
        end

        {{:ok, :stopped}, %{new_state | tailscale_override_dns: false}}

      config.enabled and state.status == :running ->
        if state.tailscale_override_dns != config.tailscale_override_dns do
          if config.tailscale_override_dns do
            Task.start(fn -> update_tailscale_dns_config(state.ts_ip, config) end)
          else
            Task.start(fn -> clear_tailscale_dns_config(config) end)
          end

          {{:ok, :updated_dns_integration},
           %{state | tailscale_override_dns: config.tailscale_override_dns}}
        else
          {{:ok, :already_synced}, state}
        end

      true ->
        {{:ok, :already_synced}, state}
    end
  end

  defp get_dns_credentials(dns_config) do
    profile_config = (dns_config.inbound_profile && dns_config.inbound_profile.config) || %{}

    auth_key = Map.get(profile_config, "ts_auth_key") || ""
    api_key = Map.get(profile_config, "ts_api_key") || ""
    tailnet = Map.get(profile_config, "ts_tailnet") || ""
    login_server = Map.get(profile_config, "login_server") || ""

    {auth_key, api_key, tailnet, login_server}
  end

  defp start_dns_node(state, dns_config) do
    if mock?() do
      timer = Process.send_after(self(), :generate_mock_log, 1000)
      {:ok, %{state | status: :running, ts_ip: "100.64.0.100", mock_timer: timer}}
    else
      storage_dir = Path.join(get_storage_base_path(), "dns_#{state.profile_id}")
      File.mkdir_p!(storage_dir)

      {auth_key, _api_key, _tailnet, login_server} = get_dns_credentials(dns_config)

      if auth_key == "" do
        {:error, "Tailscale auth key not configured"}
      else
        case bootstrap_namespace(state.profile_id, storage_dir, auth_key, login_server) do
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
      cleanup_namespace(state.profile_id)
      if state.ts_port, do: stop_port_process(state.ts_port)
      %{state | status: :stopped, ts_ip: nil, ts_port: nil, error_reason: nil}
    end
  end

  # --- Namespace Setup & Linux Commands ---

  defp bootstrap_namespace(profile_id, storage_dir, auth_key, login_server) do
    ns = "hermit_dns_#{profile_id}"
    host_if = "dns_h_#{profile_id}"
    ns_if = "dns_n_#{profile_id}"
    table_id = 1000 + profile_id
    host_ip = "10.251.#{profile_id}.1"
    ns_ip = "10.251.#{profile_id}.2"
    subnet = "10.251.#{profile_id}.0/30"
    port = 5400 + profile_id

    cleanup_namespace(profile_id)

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

    result =
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
           {:ok, _} <- run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", "eth0", "mtu", "1400"]),
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
          # NAT routing on Host
          {:ok, _} <-
            run_cmd("iptables", [
              "-t",
              "nat",
              "-I",
              "POSTROUTING",
              "-s",
              subnet,
              "-j",
              "MASQUERADE"
            ]),
          {:ok, _} <- run_cmd("iptables", ["-I", "FORWARD", "-s", subnet, "-j", "ACCEPT"]),
          {:ok, _} <-
            run_cmd("iptables", [
              "-I",
              "FORWARD",
              "-d",
              subnet,
              "-j",
              "ACCEPT"
            ]),
           # DNAT port redirection inside namespace
           {:ok, _} <-
             run_cmd("ip", [
               "netns",
               "exec",
               ns,
               "iptables",
               "-t",
               "nat",
               "-A",
               "PREROUTING",
               "-p",
               "udp",
               "--dport",
               "53",
               "-j",
               "DNAT",
               "--to-destination",
               "#{host_ip}:#{port}"
             ]),
          {:ok, _} <-
            run_cmd("ip", [
              "netns",
              "exec",
              ns,
              "iptables",
              "-t",
              "nat",
              "-A",
              "PREROUTING",
              "-p",
              "tcp",
              "--dport",
              "53",
              "-j",
              "DNAT",
              "--to-destination",
              "#{host_ip}:#{port}"
            ]),
          # Allow forwarding inside the namespace (to bypass Tailscale filter drops)
          {:ok, _} <-
            run_cmd("ip", [
              "netns",
              "exec",
              ns,
              "iptables",
              "-I",
              "FORWARD",
              "1",
              "-j",
              "ACCEPT"
            ]),

          # Source policy routing on host (replacing global route)
          {:ok, _} <-
            run_cmd("ip", ["rule", "add", "from", host_ip, "to", "100.64.0.0/10", "table", to_string(table_id)]),
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
        :ok
      else
        {:error, reason} -> {:error, reason}
      end

    case result do
      :ok ->
        socket_path = "/run/tailscaled.dns_#{profile_id}.socket"
        File.rm(socket_path)

        state_path = Path.join(storage_dir, "tailscaled.state")
        pid_path = Path.join(storage_dir, "tailscaled.pid")

        port_args = [
          "netns",
          "exec",
          ns,
          "tailscaled",
          "--socket=#{socket_path}",
          "--state=#{state_path}",
          "--port=#{41640 + profile_id}",
          "--no-logs-no-support"
        ]

        try do
          daemon_port = Port.open({:spawn_executable, "/usr/bin/ip"}, [:binary, args: port_args])

          case Port.info(daemon_port, :os_pid) do
            {:os_pid, os_pid} -> File.write!(pid_path, "#{os_pid}")
            _ -> :ok
          end

          wait_for_socket(socket_path)

          ts_up_args = [
            "netns",
            "exec",
            ns,
            "tailscale",
            "--socket=#{socket_path}",
            "up",
            "--authkey=#{auth_key}",
            "--accept-dns=true",
            "--accept-routes=false",
            "--hostname=hermit-dns-#{profile_id}",
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
              # Avoid masquerading DNS query packets forwarded from tailscale0 to host
              _ =
                run_cmd("ip", [
                  "netns",
                  "exec",
                  ns,
                  "iptables",
                  "-t",
                  "nat",
                  "-I",
                  "POSTROUTING",
                  "-p",
                  "udp",
                  "-d",
                  host_ip,
                  "--dport",
                  to_string(port),
                  "-j",
                  "RETURN"
                ])

              _ =
                run_cmd("ip", [
                  "netns",
                  "exec",
                  ns,
                  "iptables",
                  "-t",
                  "nat",
                  "-I",
                  "POSTROUTING",
                  "-p",
                  "tcp",
                  "-d",
                  host_ip,
                  "--dport",
                  to_string(port),
                  "-j",
                  "RETURN"
                ])

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
              stop_tailscaled_by_pid(pid_path)
              {:error, {:tailscale_up_failed, reason}}
          end
        rescue
          e -> {:error, {:spawn_failed, e}}
        end

      {:error, reason} ->
        cleanup_namespace(profile_id)
        {:error, reason}
    end
  end

  defp cleanup_namespace(profile_id) do
    ns = "hermit_dns_#{profile_id}"
    host_if = "dns_h_#{profile_id}"
    table_id = 1000 + profile_id
    host_ip = "10.251.#{profile_id}.1"
    subnet = "10.251.#{profile_id}.0/30"

    System.cmd("ip", ["link", "delete", host_if])

    if netns_exists?(ns) do
      System.cmd("ip", ["netns", "del", ns])
    end

    # Clean up netns DNS config directory
    File.rm_rf("/etc/netns/#{ns}")

    System.cmd("ip", ["rule", "delete", "from", host_ip, "to", "100.64.0.0/10", "table", to_string(table_id)])
    System.cmd("ip", ["route", "flush", "table", to_string(table_id)])

    System.cmd("iptables", ["-t", "nat", "-D", "POSTROUTING", "-s", subnet, "-j", "MASQUERADE"])
    System.cmd("iptables", ["-D", "FORWARD", "-s", subnet, "-j", "ACCEPT"])

    System.cmd("iptables", [
      "-D",
      "FORWARD",
      "-d",
      subnet,
      "-j",
      "ACCEPT"
    ])

    :ok
  end

  # --- Tailscale DNS Config API Update ---

  defp update_tailscale_dns_config(dns_ip, dns_config) do
    {_auth_key, api_key, tailnet, _login} = get_dns_credentials(dns_config)

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

  defp clear_tailscale_dns_config(dns_config) do
    {_auth_key, api_key, tailnet, _login} = get_dns_credentials(dns_config)

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
  defp send_mock_query(profile_id) do
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

    port = 5400 + profile_id

    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        :gen_udp.send(socket, {127, 0, 0, 1}, port, packet)
        :gen_udp.close(socket)

      _ ->
        :ok
    end
  end
end
