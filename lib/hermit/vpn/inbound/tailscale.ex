defmodule Hermit.Vpn.Inbound.Tailscale do
  @behaviour Hermit.Vpn.Inbound
  require Logger

  @impl true
  def bootstrap(pair_id, _outbound_if, storage_dir, config) do
    config = Map.new(config, fn {k, v} -> {to_string(k), v} end)
    wg_name = "hermit_wg_#{pair_id}"
    ts_name = "hermit_ts_#{pair_id}"

    ts_auth_key =
      Map.get(config, "ts_auth_key") ||
        Map.get(config, :ts_auth_key) ||
        System.get_env("TAILSCALE_AUTH_KEY") ||
        System.get_env("TS_AUTHKEY") ||
        (Application.get_env(:hermit, :docker) &&
           Application.get_env(:hermit, :docker)[:tailscale_auth_key]) ||
        ""

    login_server = Map.get(config, "login_server")

    advertise_exit_node =
      case Map.get(config, "advertise_exit_node") do
        false -> false
        "false" -> false
        nil -> true
        _ -> true
      end

    dns_mode = Map.get(config, "dns_mode") || "default"

    cond do
      err = get_mock_error() ->
        {:error, err}

      mock?() ->
        Logger.info("Mock: Starting Tailscale #{ts_name} in netns #{wg_name}")
        port = Port.open({:spawn, "cat"}, [:binary])
        {:ok, port}

      true ->
        state_dir = Path.join([storage_dir, "tailscale"])
        File.mkdir_p!(state_dir)

        socket_path = "/run/tailscaled.#{pair_id}.socket"
        File.rm(socket_path)

        pid_path = Path.join(state_dir, "tailscaled.pid")
        state_path = Path.join(state_dir, "tailscaled.state")

        Logger.info("Starting tailscaled daemon in netns #{wg_name}")

        log_path = Path.join(state_dir, "tailscaled.log")
        _ = File.rm(log_path)

        ts_port = resolve_port(pair_id, config)
        claim_port(pair_id, ts_port)

        shell_cmd =
          "GOMEMLIMIT=32MiB GOGC=50 ip netns exec #{wg_name} tailscaled --socket=#{socket_path} --state=#{state_path} --port=#{ts_port} --no-logs-no-support > #{log_path} 2>&1 & echo $! > #{pid_path} && wait"

        try do
          # Port is owned by the calling process (PairWorker)
          port =
            Port.open({:spawn_executable, "/bin/sh"}, [
              :binary,
              args: ["-c", shell_cmd]
            ])

          # Wait up to 2 seconds for socket creation
          wait_for_socket(socket_path)

          # Setup inbound DNAT and port-preserving SNAT rules on container default namespace
          setup_tailscale_host_nat(pair_id, ts_port)

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

          wait_for_dns_resolve(wg_name, hosts)

          # Authenticate Tailscale and set exit node options
          ts_up_args = [
            "netns",
            "exec",
            wg_name,
            "tailscale",
            "--socket=#{socket_path}",
            "up",
            "--reset",
            "--authkey=#{ts_auth_key}",
            "--accept-dns=#{dns_mode == "default"}",
            "--accept-routes=false",
            "--stateful-filtering=false",
            "--hostname=hermit-node-#{String.replace(pair_id, "_", "-")}",
            "--timeout=30s"
          ]

          # Append login-server for custom control plane (e.g. Headscale) if present
          ts_up_args =
            if login_server && login_server != "" do
              ts_up_args ++ ["--login-server=#{login_server}"]
            else
              ts_up_args
            end

          ts_up_args =
            append_advertise_args(ts_up_args, config, %{
              pair_id: pair_id,
              wg_name: wg_name,
              socket_path: socket_path,
              advertise_exit_node: advertise_exit_node,
              ts_auth_key: ts_auth_key
            })

          case run_cmd("ip", ts_up_args) do
            {:ok, _} ->
              dns_resolvers = Map.get(config, "dns_resolvers")
              dns_mode = Map.get(config, "dns_mode")

              should_update_dns =
                cond do
                  (dns_mode == "custom" and dns_resolvers) && String.trim(dns_resolvers) != "" ->
                    true

                  dns_mode == "default" ->
                    true

                  is_binary(dns_resolvers) and String.trim(dns_resolvers) != "" ->
                    true

                  true ->
                    false
                end

              if should_update_dns do
                dns_resolvers_str = if dns_mode == "default", do: "", else: dns_resolvers || ""

                case update_dns_settings_local(pair_id, dns_mode, dns_resolvers_str) do
                  {:ok, _} ->
                    Logger.info("Local DNS settings updated successfully.")

                  {:error, reason} ->
                    Logger.warning("Failed to update local DNS: #{inspect(reason)}")
                end
              end

              {:ok, port}

            {:error, reason} ->
              stop_tailscaled_by_pid(pid_path)
              {:error, {:tailscale_up_failed, reason}}
          end
        rescue
          e ->
            {:error, {:spawn_failed, e}}
        end
    end
  end

  @impl true
  def update_settings(pair_id, config) do
    wg_name = "hermit_wg_#{pair_id}"

    cond do
      err = get_mock_error() ->
        {:error, err}

      mock?() ->
        Logger.info("Mock: Updating Tailscale settings for #{pair_id} to #{inspect(config)}")
        {:ok, :updated}

      true ->
        config = Map.new(config, fn {k, v} -> {to_string(k), v} end)
        socket_path = "/run/tailscaled.#{pair_id}.socket"
        login_server = Map.get(config, "login_server")

        advertise_exit_node =
          case Map.get(config, "advertise_exit_node") do
            false -> false
            "false" -> false
            nil -> true
            _ -> true
          end

        dns_mode = Map.get(config, "dns_mode") || "default"

        ts_up_args = [
          "netns",
          "exec",
          wg_name,
          "tailscale",
          "--socket=#{socket_path}",
          "up",
          "--reset",
          "--accept-dns=#{dns_mode == "default"}",
          "--accept-routes=false",
          "--stateful-filtering=false",
          "--hostname=hermit-node-#{String.replace(pair_id, "_", "-")}",
          "--timeout=30s"
        ]

        ts_up_args =
          if login_server && login_server != "" do
            ts_up_args ++ ["--login-server=#{login_server}"]
          else
            ts_up_args
          end

        update_auth_key =
          Map.get(config, "ts_auth_key") ||
            Map.get(config, :ts_auth_key) ||
            System.get_env("TAILSCALE_AUTH_KEY") ||
            System.get_env("TS_AUTHKEY") ||
            (Application.get_env(:hermit, :docker) &&
               Application.get_env(:hermit, :docker)[:tailscale_auth_key]) ||
            ""

        ts_up_args =
          append_advertise_args(ts_up_args, config, %{
            pair_id: pair_id,
            wg_name: wg_name,
            socket_path: socket_path,
            advertise_exit_node: advertise_exit_node,
            ts_auth_key: update_auth_key
          })

        case run_cmd("ip", ts_up_args) do
          {:ok, _} ->
            dns_resolvers = Map.get(config, "dns_resolvers")
            dns_mode = Map.get(config, "dns_mode")

            should_update_dns =
              cond do
                (dns_mode == "custom" and dns_resolvers) && String.trim(dns_resolvers) != "" ->
                  true

                dns_mode == "default" ->
                  true

                is_binary(dns_resolvers) and String.trim(dns_resolvers) != "" ->
                  true

                true ->
                  false
              end

            if should_update_dns do
              dns_resolvers_str = if dns_mode == "default", do: "", else: dns_resolvers || ""

              case update_dns_settings_local(pair_id, dns_mode, dns_resolvers_str) do
                {:ok, _} ->
                  Logger.info("Local DNS settings updated successfully.")

                {:error, reason} ->
                  Logger.warning("Failed to update local DNS: #{inspect(reason)}")
              end
            end

            {:ok, :updated}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def cleanup(pair_id, storage_dir) do
    if mock?() do
      Logger.info("Mock: Stopping Tailscale for pair #{pair_id}")
      :ok
    else
      # 1. Attempt to delete the device from Tailscale tailnet via API
      api_delete_result = try_delete_via_api(pair_id)

      deleted_via_api? =
        case api_delete_result do
          {:ok, status} when status in [:deleted, :not_found] -> true
          _ -> false
        end

      pid_path = Path.join([storage_dir, "tailscale", "tailscaled.pid"])
      Logger.info("Stopping Tailscale daemon for pair: hermit_ts_#{pair_id}")

      socket_path = "/run/tailscaled.#{pair_id}.socket"

      # 2. Attempt to logout from Tailscale to remove the node from tailnet (if ephemeral and not already deleted via API), then shutdown
      if File.exists?(socket_path) do
        try do
          if not deleted_via_api? do
            Logger.info("Logging out Tailscale node for pair: hermit_ts_#{pair_id}")
            run_cmd_timeout("tailscale", ["--socket=#{socket_path}", "logout"], 3)
            Process.sleep(500)
          end

          run_cmd_timeout("tailscale", ["--socket=#{socket_path}", "shutdown"], 2)
          Process.sleep(200)
        rescue
          _ -> :ok
        end
      end

      # 3. Forcefully kill only this specific tailscaled process using its unique socket argument (avoids killing other pairs)
      try do
        System.cmd("pkill", ["-9", "-f", "tailscaled.*#{pair_id}.socket"])
      rescue
        _ -> :ok
      end

      # 4. Stop tailscaled daemon process via stored PID (kills the ip wrapper process if still alive)
      stop_tailscaled_by_pid(pid_path)

      # 5. Clean up Unix domain socket from the container filesystem
      File.rm(socket_path)

      # 6. Clean up nftables host NAT rules
      cleanup_tailscale_host_nat(pair_id)

      :ok
    end
  end

  defp try_delete_via_api(pair_id) do
    case Hermit.Repo.get(Hermit.Vpn.VpnPair, pair_id) do
      nil ->
        Logger.info("VpnPair #{pair_id} not found in DB during cleanup. Skipping API delete.")
        :ok

      pair ->
        pair = Hermit.Repo.preload(pair, [:inbound_profile])
        config = pair.inbound_config || %{}
        profile_config = (pair.inbound_profile && pair.inbound_profile.config) || %{}
        merged_config = Map.merge(profile_config, config)
        expected_hostname = "hermit-node-#{String.replace(pair_id, "_", "-")}"

        delete_device_by_hostname(expected_hostname, merged_config)
    end
  end

  @doc """
  Deletes a Tailscale device from the tailnet by hostname using API credentials from config or profile.
  """
  def delete_device_by_hostname(expected_hostname, config_or_profile) do
    config =
      case config_or_profile do
        %Hermit.Vpn.InboundProfile{config: c} when is_map(c) -> c
        c when is_map(c) -> c
        _ -> %{}
      end

    tailnet =
      Map.get(config, "ts_tailnet") || Map.get(config, :ts_tailnet) ||
        Hermit.Vpn.Setting.get_value("tailscale_tailnet", "") ||
        "-"

    tailnet = if tailnet == "", do: "-", else: tailnet

    case get_api_token(config) do
      {:ok, token} ->
        devices_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/devices"
        headers = [{"authorization", "Bearer #{token}"}]

        Logger.info("Attempting to delete Tailscale device #{expected_hostname} via API...")

        case Req.get(devices_url, headers: headers) do
          {:ok, %{status: 200, body: %{"devices" => devices}}} ->
            device =
              Enum.find(devices, fn dev ->
                dev["hostname"] == expected_hostname or
                  String.starts_with?(dev["name"] || "", expected_hostname <> ".")
              end)

            if device do
              device_id = device["id"]
              delete_url = "https://api.tailscale.com/api/v2/device/#{device_id}"

              case Req.delete(delete_url, headers: headers) do
                {:ok, %{status: 200}} ->
                  Logger.info(
                    "Successfully deleted Tailscale device #{expected_hostname} from tailnet."
                  )

                  {:ok, :deleted}

                {:ok, %{status: status, body: body}} ->
                  Logger.error(
                    "Failed to delete Tailscale device (HTTP #{status}): #{inspect(body)}"
                  )

                  {:error, :api_delete_failed}

                {:error, reason} ->
                  Logger.error("Failed to call Tailscale delete API: #{inspect(reason)}")
                  {:error, reason}
              end
            else
              Logger.info(
                "Tailscale device #{expected_hostname} not found in tailnet, skipping API delete."
              )

              {:ok, :not_found}
            end

          {:ok, %{status: status, body: body}} ->
            Logger.error(
              "Failed to fetch Tailscale devices for deletion (HTTP #{status}): #{inspect(body)}"
            )

            {:error, :api_fetch_failed}

          {:error, reason} ->
            Logger.error("Failed to call Tailscale devices API for deletion: #{inspect(reason)}")

            {:error, reason}
        end

      {:error, _reason} ->
        Logger.info("Tailscale API credentials not configured. Skipping API device deletion.")
        {:ok, :skipped}
    end
  rescue
    e ->
      Logger.error("Error during delete_device_by_hostname: #{inspect(e)}")
      {:error, {:exception, e}}
  end

  defp run_cmd_timeout(cmd, args, timeout_secs) do
    case System.find_executable("timeout") do
      nil ->
        task =
          Task.async(fn ->
            try do
              System.cmd(cmd, args, stderr_to_stdout: true)
            rescue
              _ -> {"error", 1}
            end
          end)

        case Task.yield(task, timeout_secs * 1000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          nil -> {"timeout", 124}
        end

      timeout_bin ->
        try do
          System.cmd(timeout_bin, ["#{timeout_secs}", cmd | args], stderr_to_stdout: true)
        rescue
          _ -> {"error", 1}
        end
    end
  end

  @impl true
  def get_status(pair_id, storage_dir) do
    wg_name = "hermit_wg_#{pair_id}"

    cond do
      err = get_mock_error() ->
        {:error, err}

      mock?() ->
        # For mock, check if directory exists
        if File.exists?(storage_dir) do
          :running
        else
          :stopped
        end

      true ->
        pid_path = Path.join([storage_dir, "tailscale", "tailscaled.pid"])

        cond do
          not netns_exists?(wg_name) ->
            :stopped

          true ->
            running =
              case File.read(pid_path) do
                {:ok, pid_str} ->
                  pid = String.trim(pid_str)
                  File.exists?("/proc/#{pid}")

                _ ->
                  false
              end

            if running, do: :running, else: :stopped
        end
    end
  end

  @impl true
  def get_network_info(pair_id, _storage_dir) do
    wg_name = "hermit_wg_#{pair_id}"

    cond do
      err = get_mock_error() ->
        {:error, err}

      mock?() ->
        %{
          ts_ips: ["100.64.0.5", "fd7a:115c:a1e0::5"],
          ts_backend_state: "Running",
          ts_user: "mock-user@example.com",
          ts_magic_dns: "hermit-node.mock-tailnet.ts.net",
          ts_exit_node: true
        }

      true ->
        socket_path = "/run/tailscaled.#{pair_id}.socket"

        ts_info =
          if File.exists?(socket_path) do
            case System.cmd(
                   "ip",
                   [
                     "netns",
                     "exec",
                     wg_name,
                     "tailscale",
                     "--socket=#{socket_path}",
                     "status",
                     "--json"
                   ],
                   stderr_to_stdout: true
                 ) do
              {output, 0} ->
                case Jason.decode(output) do
                  {:ok, data} ->
                    self_node = Map.get(data, "Self")
                    self_node = if is_map(self_node), do: self_node, else: %{}
                    ips = Map.get(self_node, "TailscaleIPs") || []
                    backend_state = Map.get(data, "BackendState") || "Unknown"

                    user_id = Map.get(self_node, "UserID") || 0
                    users = Map.get(data, "User")
                    users = if is_map(users), do: users, else: %{}
                    user_info = Map.get(users, to_string(user_id))
                    user_info = if is_map(user_info), do: user_info, else: %{}
                    user_login = Map.get(user_info, "LoginName") || "Unknown"

                    dns_name = Map.get(self_node, "DNSName") || ""
                    exit_node = Map.get(self_node, "ExitNode") || false

                    %{
                      ts_ips: ips,
                      ts_backend_state: backend_state,
                      ts_user: user_login,
                      ts_magic_dns: dns_name,
                      ts_exit_node: exit_node
                    }

                  _ ->
                    nil
                end

              _ ->
                nil
            end
          else
            nil
          end

        ts_defaults = %{
          ts_ips: [],
          ts_backend_state: "Offline",
          ts_user: "Unknown",
          ts_magic_dns: "",
          ts_exit_node: false
        }

        ts_info || ts_defaults
    end
  end

  @doc """
  Approves advertised routes (exit nodes, subnet routes) for a Tailscale node using Tailscale API.
  """
  @impl true
  def approve_exit_node(pair_id) do
    cond do
      mock?() ->
        Logger.info("Mock: Approving Tailscale routes for #{pair_id}")
        {:ok, :approved}

      true ->
        pair =
          case Hermit.Repo.get(Hermit.Vpn.VpnPair, pair_id) do
            nil -> nil
            p -> Hermit.Repo.preload(p, :inbound_profile)
          end

        config = get_inbound_config(pair)
        profile_config = (pair && pair.inbound_profile && pair.inbound_profile.config) || %{}
        merged_config = Map.merge(profile_config, config)

        tailnet =
          Map.get(config, "ts_tailnet") ||
            (pair && pair.inbound_profile && pair.inbound_profile.config["ts_tailnet"]) ||
            Hermit.Vpn.Setting.get_value("tailscale_tailnet", "") ||
            "-"

        tailnet = if tailnet == "", do: "-", else: tailnet

        case get_api_token(merged_config) do
          {:ok, token} ->
            # Handle Routes approval (Exit node or Subnets)
            advertise_exit_node =
              case Map.get(config, "advertise_exit_node") do
                false -> false
                "false" -> false
                nil -> true
                _ -> true
              end

            advertise_routes =
              case Map.get(config, "routing_targets") do
                targets when is_binary(targets) and targets != "" ->
                  parsed = Hermit.Vpn.RoutingParser.parse(targets)
                  Hermit.Vpn.RoutingParser.format_subnets(parsed.subnets)

                _ ->
                  Map.get(config, "advertise_routes") || ""
              end

            if advertise_exit_node or clean_routes(advertise_routes) != "" do
              expected_hostname = "hermit-node-#{String.replace(pair_id, "_", "-")}"
              Logger.info("Starting Tailscale routes approval for #{expected_hostname}")
              do_approve_exit_node(token, tailnet, expected_hostname, 5)
            else
              Logger.info(
                "Node #{pair_id} is not advertising any routes. Skipping routes approval."
              )

              {:ok, :skipped}
            end

          {:error, reason} ->
            Logger.warning(
              "Tailscale API token not available (#{inspect(reason)}). Skipping auto-approval of routes."
            )

            {:error, :missing_credentials}
        end
    end
  end

  defp do_approve_exit_node(_token, _tailnet, expected_hostname, 0) do
    Logger.error("Failed to find Tailscale device #{expected_hostname} after multiple retries.")
    {:error, :device_not_found}
  end

  defp do_approve_exit_node(token, tailnet, expected_hostname, retries_left) do
    devices_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/devices"
    headers = [{"authorization", "Bearer #{token}"}]

    case Req.get(devices_url, headers: headers) do
      {:ok, %{status: 200, body: %{"devices" => devices}}} ->
        device =
          Enum.find(devices, fn dev ->
            dev["hostname"] == expected_hostname or
              String.starts_with?(dev["name"] || "", expected_hostname <> ".")
          end)

        if device do
          device_id = device["id"]
          routes_url = "https://api.tailscale.com/api/v2/device/#{device_id}/routes"

          case Req.get(routes_url, headers: headers) do
            {:ok, %{status: 200, body: %{"advertisedRoutes" => advertised_routes}}} ->
              if advertised_routes != [] do
                Logger.info(
                  "Found advertised routes: #{inspect(advertised_routes)}. Auto-approving..."
                )

                routes_payload = %{routes: advertised_routes}

                case Req.post(routes_url, json: routes_payload, headers: headers) do
                  {:ok, %{status: 200}} ->
                    Logger.info("Successfully auto-approved routes for #{expected_hostname}")
                    {:ok, :approved}

                  {:ok, %{status: status, body: body}} ->
                    Logger.error(
                      "Failed to approve Tailscale routes (HTTP #{status}): #{inspect(body)}"
                    )

                    {:error, {:routes_api_failed, status, body}}

                  {:error, reason} ->
                    Logger.error("Failed to call Tailscale routes API: #{inspect(reason)}")
                    {:error, reason}
                end
              else
                Logger.info(
                  "No advertised routes found yet for #{expected_hostname}. Retrying in 3s... (#{retries_left - 1} left)"
                )

                Process.sleep(3000)
                do_approve_exit_node(token, tailnet, expected_hostname, retries_left - 1)
              end

            {:ok, %{status: status, body: body}} ->
              Logger.error("Failed to fetch device routes (HTTP #{status}): #{inspect(body)}")
              {:error, {:routes_fetch_failed, status, body}}

            {:error, reason} ->
              Logger.error("Failed to call Tailscale routes fetch API: #{inspect(reason)}")
              {:error, reason}
          end
        else
          Logger.info(
            "Tailscale device #{expected_hostname} not registered yet. Retrying in 3 seconds... (#{retries_left - 1} left)"
          )

          Process.sleep(3000)
          do_approve_exit_node(token, tailnet, expected_hostname, retries_left - 1)
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to fetch Tailscale devices (HTTP #{status}): #{inspect(body)}")
        {:error, {:devices_api_failed, status, body}}

      {:error, reason} ->
        Logger.error("Failed to call Tailscale devices API: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Updates the Tailscale DNS nameservers for the tailnet using the Tailscale API.
  """
  def update_dns_settings_local(pair_id, dns_mode, dns_resolvers_str) do
    cond do
      mock?() ->
        Logger.info(
          "Mock: Updating local DNS settings for #{pair_id} to #{dns_mode} (resolvers: #{dns_resolvers_str})"
        )

        {:ok, :updated}

      true ->
        netns_dns_dir = "/etc/netns/hermit_wg_#{pair_id}"

        try do
          File.mkdir_p!(netns_dns_dir)

          dns_servers =
            if dns_mode == "default" do
              ["1.1.1.1", "8.8.8.8"]
            else
              String.split(dns_resolvers_str, [",", "\n"])
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))
            end

          if dns_servers != [] do
            dns_lines = dns_servers |> Enum.map(&"nameserver #{&1}") |> Enum.join("\n")
            File.write!(Path.join(netns_dns_dir, "resolv.conf"), dns_lines)

            Logger.info(
              "Successfully updated local DNS config for hermit_wg_#{pair_id} to: #{inspect(dns_servers)}"
            )

            {:ok, :updated}
          else
            File.rm(Path.join(netns_dns_dir, "resolv.conf"))
            {:ok, :updated}
          end
        rescue
          e ->
            Logger.error("Failed to update local DNS for hermit_wg_#{pair_id}: #{inspect(e)}")
            {:error, e}
        end
    end
  end

  # --- Internal Helpers ---

  defp run_cmd(cmd, args) do
    flat_args = List.flatten(args)
    Logger.debug("Running: #{cmd} #{Enum.join(flat_args, " ")}")

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

  defp stop_tailscaled_by_pid(pid_path) do
    if File.exists?(pid_path) do
      case File.read(pid_path) do
        {:ok, pid_str} ->
          pid = String.trim(pid_str)
          Logger.info("Killing tailscaled process: #{pid}")

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

  defp netns_exists?(ns_name) do
    case System.cmd("ip", ["netns", "list"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          String.starts_with?(line, ns_name)
        end)

      _ ->
        false
    end
  end

  def resolve_tags(_pair_id, config, _opts \\ %{}) do
    explicit_tags =
      Map.get(config, "advertise_tags") ||
        Map.get(config, :advertise_tags) ||
        Map.get(config, "tag") ||
        Map.get(config, :tag)

    cond do
      is_binary(explicit_tags) and String.trim(explicit_tags) in ["none", "false"] ->
        nil

      is_binary(explicit_tags) and String.trim(explicit_tags) != "" ->
        explicit_tags
        |> String.split([",", " "], trim: true)
        |> Enum.map(fn t ->
          t = String.trim(t)
          if String.starts_with?(t, "tag:"), do: t, else: "tag:#{t}"
        end)
        |> Enum.join(",")

      true ->
        "tag:hermit"
    end
  end

  def oauth_auth_key?(key) when is_binary(key) do
    String.starts_with?(key, "tskey-client-") or String.contains?(key, "tskey-client-")
  end

  def oauth_auth_key?(_), do: false

  @doc """
  Resolves a valid Tailscale REST API access token from a raw key string or profile/config map.
  Supports:
  - Direct API access tokens (`tskey-api-...`)
  - OAuth client credentials (`tskey-client-[client_id]-[secret]`), dynamically exchanged for an access token
  - Fallbacks to settings and environment variables
  """
  def get_api_token(key_or_config)

  def get_api_token(key) when is_binary(key) do
    trimmed = String.trim(key)

    cond do
      trimmed == "" ->
        {:error, :empty_key}

      String.starts_with?(trimmed, "tskey-auth-") ->
        Logger.warning(
          "Tailscale key is a pre-authenticated auth key (tskey-auth-). Pre-auth keys cannot be used with Tailscale Admin APIs. Please use an OAuth client key (tskey-client-) or API token (tskey-api-)."
        )

        {:error, :unsupported_auth_key}

      String.starts_with?(trimmed, "tskey-api-") ->
        {:ok, trimmed}

      oauth_auth_key?(trimmed) ->
        exchange_oauth_token(trimmed)

      mock?() ->
        {:ok, "mock-access-token"}

      true ->
        {:error, :unknown_key_format}
    end
  end

  def get_api_token(config) when is_map(config) do
    key =
      Map.get(config, "ts_auth_key") ||
        Map.get(config, :ts_auth_key) ||
        Map.get(config, "ts_api_key") ||
        Map.get(config, :ts_api_key) ||
        System.get_env("TAILSCALE_AUTH_KEY") ||
        System.get_env("TS_AUTHKEY") ||
        System.get_env("TAILSCALE_API_KEY") ||
        System.get_env("TS_API_KEY") ||
        Hermit.Vpn.Setting.get_value("tailscale_api_key", "") ||
        (Application.get_env(:hermit, :docker) &&
           Application.get_env(:hermit, :docker)[:tailscale_auth_key]) ||
        ""

    get_api_token(key)
  end

  def get_api_token(_), do: {:error, :invalid_argument}

  @doc """
  Exchanges an OAuth client secret (`tskey-client-...`) for a short-lived Bearer access token.
  """
  def exchange_oauth_token(secret) when is_binary(secret) do
    if mock?() do
      {:ok, "mock-access-token"}
    else
      clean_secret = secret |> String.split("?") |> List.first() |> String.trim()

      case Regex.run(~r/^tskey-client-([^-]+)-.+/, clean_secret) do
        [_, client_id] ->
          url = "https://api.tailscale.com/api/v2/oauth/token"

          case Req.post(url,
                 form: [
                   client_id: client_id,
                   client_secret: clean_secret,
                   grant_type: "client_credentials"
                 ]
               ) do
            {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
              {:ok, token}

            {:ok, %{status: status, body: body}} ->
              Logger.error(
                "Failed to exchange Tailscale OAuth token (HTTP #{status}): #{inspect(body)}"
              )

              {:error, {:oauth_failed, status, body}}

            {:error, reason} ->
              Logger.error("Network error exchanging Tailscale OAuth token: #{inspect(reason)}")
              {:error, reason}
          end

        _ ->
          Logger.error("Could not parse Client ID from Tailscale OAuth key: #{secret}")
          {:error, :invalid_oauth_key_format}
      end
    end
  end

  defp get_current_tags(wg_name, socket_path) do
    if File.exists?(socket_path) do
      case System.cmd(
             "ip",
             [
               "netns",
               "exec",
               wg_name,
               "tailscale",
               "--socket=#{socket_path}",
               "status",
               "--json"
             ],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, %{"Self" => %{"Tags" => tags}}} when is_list(tags) ->
              tags

            _ ->
              []
          end

        _ ->
          []
      end
    else
      []
    end
  end

  defp get_inbound_config(pair) do
    config =
      cond do
        pair && pair.inbound_config && map_size(pair.inbound_config) > 0 ->
          pair.inbound_config

        pair && pair.inbound_profile ->
          pair.inbound_profile.config || %{}

        true ->
          %{}
      end

    Map.new(config, fn {k, v} -> {to_string(k), v} end)
  end

  @doc """
  Appends Tailscale `up` advertise-related args derived from the inbound config.

  Single source of truth shared by `bootstrap/4` and `update_settings/2`, so the
  advertised exit-node, app-connector and subnet-route flags cannot drift between
  the initial bring-up, live config updates, and any recovery that re-bootstraps.
  """
  def append_advertise_args(ts_up_args, config, opts) do
    %{
      pair_id: pair_id,
      wg_name: wg_name,
      socket_path: socket_path,
      advertise_exit_node: advertise_exit_node
    } = opts

    ts_up_args =
      if advertise_exit_node do
        ts_up_args ++ ["--advertise-exit-node"]
      else
        ts_up_args ++ ["--advertise-exit-node=false"]
      end

    tag = resolve_tags(pair_id, config, opts)
    current_tags = get_current_tags(wg_name, socket_path)

    ts_up_args =
      cond do
        tag != nil ->
          ts_up_args ++ ["--advertise-tags=#{tag}"]

        current_tags != [] ->
          ts_up_args ++ ["--advertise-tags=#{Enum.join(current_tags, ",")}"]

        true ->
          ts_up_args
      end

    advertise_routes =
      case Map.get(config, "routing_targets") do
        targets when is_binary(targets) and targets != "" ->
          parsed = Hermit.Vpn.RoutingParser.parse(targets)
          Hermit.Vpn.RoutingParser.format_subnets(parsed.subnets)

        _ ->
          Map.get(config, "advertise_routes") || ""
      end

    if clean_routes(advertise_routes) != "" do
      ts_up_args ++ ["--advertise-routes=#{clean_routes(advertise_routes)}"]
    else
      ts_up_args ++ ["--advertise-routes="]
    end
  end

  defp clean_routes(routes) when is_binary(routes) do
    routes
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(",")
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end

  defp get_mock_error do
    config = Application.get_env(:hermit, :docker, [])

    Keyword.get(config, :mock_error)
  end

  defp wait_for_dns_resolve(wg_name, hosts, retries \\ 10)
  defp wait_for_dns_resolve(_wg_name, _hosts, 0), do: :ok

  defp wait_for_dns_resolve(wg_name, hosts, retries) do
    resolved? =
      Enum.any?(hosts, fn host ->
        case System.cmd("ip", ["netns", "exec", wg_name, "getent", "hosts", host]) do
          {_, 0} -> true
          _ -> false
        end
      end)

    if resolved? do
      Logger.info("DNS resolution is ready inside namespace #{wg_name}")
      :ok
    else
      Process.sleep(500)
      wait_for_dns_resolve(wg_name, hosts, retries - 1)
    end
  end

  @doc """
  Resolves the UDP port for tailscaled to bind.
  Supports explicit `ts_port`, configured `ts_port_range` (or global setting `tailscale_port_range`),
  and falls back to finding a free port within the range.
  """
  def resolve_port(pair_id, config) do
    explicit_port = Map.get(config, "ts_port") || Map.get(config, :ts_port)

    case parse_port(explicit_port) do
      port when is_integer(port) and port > 0 ->
        port

      _ ->
        range_str =
          Map.get(config, "ts_port_range") ||
            Map.get(config, :ts_port_range) ||
            Hermit.Vpn.Setting.get_value("tailscale_port_range", "41642-41700")

        {start_port, end_port} = parse_port_range(range_str)
        find_free_port_in_range(pair_id, start_port, end_port)
    end
  end

  defp parse_port(val) when is_integer(val), do: val

  defp parse_port(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {port, ""} -> port
      _ -> nil
    end
  end

  defp parse_port(_), do: nil

  defp parse_port_range(str) when is_binary(str) do
    case String.split(str, ["-", "..", ":"]) |> Enum.map(&String.trim/1) do
      [s, e] ->
        with {start_p, ""} <- Integer.parse(s),
             {end_p, ""} <- Integer.parse(e),
             true <- start_p > 0 and end_p >= start_p do
          {start_p, end_p}
        else
          _ -> {41642, 41700}
        end

      _ ->
        {41642, 41700}
    end
  end

  defp parse_port_range(_), do: {41642, 41700}

  defp find_free_port_in_range(pair_id, start_port, end_port) do
    total = max(1, end_port - start_port + 1)
    offset = :erlang.phash2(pair_id, total)
    start_candidate = start_port + offset

    candidates =
      if start_candidate > start_port do
        Stream.concat(start_candidate..end_port, start_port..(start_candidate - 1))
      else
        start_port..end_port
      end

    Enum.find(candidates, 0, fn p -> port_free?(pair_id, p) end)
  end

  defp port_free?(pair_id, port) do
    registry_free?(pair_id, port) and os_port_free?(port)
  end

  defp registry_free?(pair_id, port) do
    case Registry.lookup(Hermit.Vpn.Registry, {:ts_port, port}) do
      [] -> true
      [{_pid, ^pair_id}] -> true
      _ -> false
    end
  end

  defp os_port_free?(port) do
    case :gen_udp.open(port, [:inet, reuseaddr: false]) do
      {:ok, socket} ->
        :gen_udp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  @doc """
  Claims and registers a port reservation for pair_id in Hermit.Vpn.Registry.
  The reservation is automatically released when the calling process terminates.
  """
  def claim_port(pair_id, port) when is_integer(port) and port > 0 do
    case Registry.register(Hermit.Vpn.Registry, {:ts_port, port}, pair_id) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
      _ -> :ok
    end
  end

  def claim_port(_pair_id, _port), do: :ok

  @doc """
  Sets up inbound DNAT, port-preserving outbound SNAT rules on the container default namespace,
  and netns policy routing table for pair_id to enable Direct Tailscale P2P connections.
  """
  def setup_tailscale_host_nat(pair_id, ts_port) when is_integer(ts_port) and ts_port > 0 do
    ns = "hermit_wg_#{pair_id}"
    table_name = "hermit_local_#{pair_id}"

    case resolve_subnet_info(pair_id, ns) do
      {:ok, subnet, host_gateway_ip, ns_ip} ->
        Hermit.Vpn.Nat.setup_nat(table_name, subnet, ns_ip, ts_port)
        Hermit.Vpn.Nat.cleanup_nat("hermit_ts_nat_#{pair_id}")

        setup_tailscale_netns_policy_routing(ns, host_gateway_ip, ts_port)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def setup_tailscale_host_nat(_pair_id, _ts_port), do: :ok

  defp resolve_subnet_info(pair_id, ns) do
    case Hermit.Vpn.SubnetPool.get_or_allocate_subnet(pair_id) do
      {:ok, %{subnet: subnet, gateway_ip: gateway_ip, ns_ip: ns_ip}}
      when is_binary(subnet) and is_binary(gateway_ip) and is_binary(ns_ip) ->
        {:ok, subnet, gateway_ip, ns_ip}

      _ ->
        case System.cmd("ip", [
               "netns",
               "exec",
               ns,
               "ip",
               "-o",
               "-4",
               "addr",
               "show",
               "dev",
               "eth0"
             ]) do
          {output, 0} ->
            case Regex.run(~r/inet\s+(10\.200\.\d+\.\d+)/, output) do
              [_, ns_ip] ->
                [a, b, c, d] = String.split(ns_ip, ".") |> Enum.map(&String.to_integer/1)
                base_d = div(d, 4) * 4
                subnet = "#{a}.#{b}.#{c}.#{base_d}/30"
                gateway_ip = "#{a}.#{b}.#{c}.#{base_d + 1}"
                {:ok, subnet, gateway_ip, ns_ip}

              _ ->
                :error
            end

          _ ->
            :error
        end
    end
  rescue
    _ -> :error
  end

  def cleanup_tailscale_host_nat(pair_id) do
    ns = "hermit_wg_#{pair_id}"
    cleanup_tailscale_netns_policy_routing(ns)
    Hermit.Vpn.Nat.cleanup_nat("hermit_local_#{pair_id}")
    Hermit.Vpn.Nat.cleanup_nat("hermit_ts_nat_#{pair_id}")
  rescue
    _ -> :ok
  end

  defp setup_tailscale_netns_policy_routing(ns, host_gateway_ip, ts_port) do
    System.cmd(
      "ip",
      ["netns", "exec", ns, "ip", "rule", "del", "sport", to_string(ts_port), "table", "200"],
      stderr_to_stdout: true
    )

    System.cmd("ip", ["netns", "exec", ns, "ip", "route", "flush", "table", "200"],
      stderr_to_stdout: true
    )

    System.cmd("ip", [
      "netns",
      "exec",
      ns,
      "ip",
      "route",
      "add",
      "default",
      "via",
      host_gateway_ip,
      "dev",
      "eth0",
      "table",
      "200"
    ])

    System.cmd("ip", [
      "netns",
      "exec",
      ns,
      "ip",
      "rule",
      "add",
      "sport",
      to_string(ts_port),
      "table",
      "200"
    ])

    System.cmd("ip", ["netns", "exec", ns, "sysctl", "-w", "net.ipv4.conf.eth0.rp_filter=0"],
      stderr_to_stdout: true
    )

    System.cmd("ip", ["netns", "exec", ns, "sysctl", "-w", "net.ipv4.conf.all.rp_filter=0"],
      stderr_to_stdout: true
    )

    :ok
  rescue
    _ -> :ok
  end

  defp cleanup_tailscale_netns_policy_routing(ns) do
    System.cmd("ip", ["netns", "exec", ns, "ip", "route", "flush", "table", "200"],
      stderr_to_stdout: true
    )
  rescue
    _ -> :ok
  end

  @doc """
  Gets the primary IPv4 address of the container default network namespace (e.g. 172.25.0.2).
  """
  def get_container_ip do
    case System.cmd("ip", ["-o", "-4", "route", "get", "8.8.8.8"]) do
      {output, 0} ->
        case Regex.run(~r/src\s+(\d+\.\d+\.\d+\.\d+)/, output) do
          [_, ip] -> ip
          _ -> get_first_non_lo_ip()
        end

      _ ->
        get_first_non_lo_ip()
    end
  rescue
    _ -> nil
  end

  defp get_first_non_lo_ip do
    case System.cmd("ip", ["-o", "-4", "addr", "show", "up"]) do
      {output, 0} ->
        case Regex.run(~r/inet\s+(\d+\.\d+\.\d+\.\d+)/, output) do
          [_, ip] -> ip
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
