defmodule Hermit.Vpn.Inbound.Tailscale do
  @behaviour Hermit.Vpn.Inbound
  require Logger

  @impl true
  def bootstrap(pair_id, _outbound_if, storage_dir, config) do
    wg_name = "hermit_wg_#{pair_id}"
    ts_name = "hermit_ts_#{pair_id}"
    ts_auth_key = Map.get(config, :ts_auth_key) || Map.get(config, "ts_auth_key") || ""
    login_server = Map.get(config, :login_server) || Map.get(config, "login_server")

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

        # Start tailscaled daemon in background inside the namespace
        port_args = [
          "netns",
          "exec",
          wg_name,
          "tailscaled",
          "--socket=#{socket_path}",
          "--state=#{state_path}",
          "--port=41641",
          "--no-logs-no-support"
        ]

        try do
          # Port is owned by the calling process (PairWorker)
          port =
            Port.open({:spawn_executable, "/usr/bin/ip"}, [
              :binary,
              args: port_args
            ])

          case Port.info(port, :os_pid) do
            {:os_pid, os_pid} ->
              File.write!(pid_path, "#{os_pid}")

            _ ->
              :ok
          end

          # Wait up to 2 seconds for socket creation
          wait_for_socket(socket_path)

          # Authenticate Tailscale and set exit node options
          ts_up_args = [
            "netns",
            "exec",
            wg_name,
            "tailscale",
            "--socket=#{socket_path}",
            "up",
            "--authkey=#{ts_auth_key}",
            "--advertise-exit-node",
            "--accept-dns=true",
            "--accept-routes=false",
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

          case run_cmd("ip", ts_up_args) do
            {:ok, _} ->
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
  def cleanup(pair_id, storage_dir) do
    if mock?() do
      Logger.info("Mock: Stopping Tailscale for pair #{pair_id}")
      :ok
    else
      pid_path = Path.join([storage_dir, "tailscale", "tailscaled.pid"])
      Logger.info("Stopping Tailscale daemon for pair: hermit_ts_#{pair_id}")

      # Stop tailscaled daemon process
      stop_tailscaled_by_pid(pid_path)

      # Clean up Unix domain socket from the container filesystem
      socket_path = "/run/tailscaled.#{pair_id}.socket"
      File.rm(socket_path)

      :ok
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
                    self_node = Map.get(data, "Self", %{})
                    ips = Map.get(self_node, "TailscaleIPs", [])
                    backend_state = Map.get(data, "BackendState", "Unknown")

                    user_id = Map.get(self_node, "UserID", 0)
                    users = Map.get(data, "User", %{})
                    user_info = Map.get(users, to_string(user_id), %{})
                    user_login = Map.get(user_info, "LoginName", "Unknown")

                    dns_name = Map.get(self_node, "DNSName", "")
                    exit_node = Map.get(self_node, "ExitNode", false)

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
  Approves advertised exit node routes for a Tailscale node using Tailscale API.
  """
  def approve_exit_node(pair_id) do
    cond do
      mock?() ->
        Logger.info("Mock: Approving Tailscale exit node for #{pair_id}")
        {:ok, :approved}

      true ->
        pair =
          case Hermit.Repo.get(Hermit.Vpn.VpnPair, pair_id) do
            nil -> nil
            p -> Hermit.Repo.preload(p, :inbound_profile)
          end

        api_key =
          (pair && pair.inbound_profile && pair.inbound_profile.config["ts_api_key"]) ||
            Hermit.Vpn.Setting.get_value("tailscale_api_key", "")

        tailnet =
          (pair && pair.inbound_profile && pair.inbound_profile.config["ts_tailnet"]) ||
            Hermit.Vpn.Setting.get_value("tailscale_tailnet", "")

        if api_key == "" or tailnet == "" do
          Logger.warning(
            "Tailscale API credentials not configured. Skipping auto-approval of exit node."
          )

          {:error, :missing_credentials}
        else
          # Hostname advertised by this node
          expected_hostname = "hermit-node-#{String.replace(pair_id, "_", "-")}"
          Logger.info("Starting Tailscale exit node approval for #{expected_hostname}")

          # Retry up to 5 times to let the device register
          do_approve_exit_node(api_key, tailnet, expected_hostname, 5)
        end
    end
  end

  defp do_approve_exit_node(_api_key, _tailnet, expected_hostname, 0) do
    Logger.error("Failed to find Tailscale device #{expected_hostname} after multiple retries.")
    {:error, :device_not_found}
  end

  defp do_approve_exit_node(api_key, tailnet, expected_hostname, retries_left) do
    # 1. Fetch devices list
    devices_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/devices"

    case Req.get(devices_url, auth: {:basic, "#{api_key}:"}) do
      {:ok, %{status: 200, body: %{"devices" => devices}}} ->
        # Find device matching hostname or name prefix
        device =
          Enum.find(devices, fn dev ->
            dev["hostname"] == expected_hostname or
              String.starts_with?(dev["name"] || "", expected_hostname <> ".")
          end)

        if device do
          device_id = device["id"]

          Logger.info(
            "Found Tailscale device #{expected_hostname} with ID #{device_id}. Approving routes..."
          )

          # 2. Approve 0.0.0.0/0 and ::/0 exit node routes
          routes_url = "https://api.tailscale.com/api/v2/device/#{device_id}/routes"
          routes_payload = %{routes: ["0.0.0.0/0", "::/0"]}

          case Req.post(routes_url, json: routes_payload, auth: {:basic, "#{api_key}:"}) do
            {:ok, %{status: 200}} ->
              Logger.info("Successfully approved exit node routes for #{expected_hostname}")
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
            "Tailscale device #{expected_hostname} not registered yet. Retrying in 3 seconds... (#{retries_left - 1} left)"
          )

          Process.sleep(3000)
          do_approve_exit_node(api_key, tailnet, expected_hostname, retries_left - 1)
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to fetch Tailscale devices (HTTP #{status}): #{inspect(body)}")
        {:error, {:devices_api_failed, status, body}}

      {:error, reason} ->
        Logger.error("Failed to call Tailscale devices API: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Internal Helpers ---

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

  defp stop_tailscaled_by_pid(pid_path) do
    if File.exists?(pid_path) do
      case File.read(pid_path) do
        {:ok, pid_str} ->
          pid = String.trim(pid_str)
          Logger.info("Killing tailscaled process: #{pid}")
          System.cmd("kill", [pid])
          Process.sleep(200)
          # Force kill if still running
          System.cmd("kill", ["-9", pid])

        _ ->
          :ok
      end
    end
  end

  defp netns_exists?(ns_name) do
    case System.cmd("ip", ["netns", "list"]) do
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

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end

  defp get_mock_error do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock_error)
  end
end
