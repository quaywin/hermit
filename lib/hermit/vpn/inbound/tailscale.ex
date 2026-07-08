defmodule Hermit.Vpn.Inbound.Tailscale do
  @behaviour Hermit.Vpn.Inbound
  require Logger

  @impl true
  def bootstrap(pair_id, _outbound_if, storage_dir, config) do
    wg_name = "hermit_wg_#{pair_id}"
    ts_name = "hermit_ts_#{pair_id}"
    ts_auth_key = Map.get(config, :ts_auth_key) || Map.get(config, "ts_auth_key") || ""
    login_server = Map.get(config, :login_server) || Map.get(config, "login_server")

    advertise_exit_node =
      case Map.get(config, :advertise_exit_node) || Map.get(config, "advertise_exit_node") do
        false -> false
        "false" -> false
        nil -> true
        _ -> true
      end

    advertise_connector =
      case Map.get(config, :advertise_connector) || Map.get(config, "advertise_connector") do
        true -> true
        "true" -> true
        _ -> false
      end

    advertise_routes =
      Map.get(config, :advertise_routes) || Map.get(config, "advertise_routes") || ""

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

          ts_up_args =
            if advertise_exit_node do
              ts_up_args ++ ["--advertise-exit-node"]
            else
              ts_up_args ++ ["--advertise-exit-node=false"]
            end

          ts_up_args =
            if advertise_connector do
              tag = get_connector_tag(pair_id, config)
              ts_up_args ++ ["--advertise-connector", "--advertise-tags=#{tag}"]
            else
              ts_up_args ++ ["--advertise-connector=false"]
            end

          ts_up_args =
            if clean_routes(advertise_routes) != "" do
              ts_up_args ++ ["--advertise-routes=#{clean_routes(advertise_routes)}"]
            else
              ts_up_args ++ ["--advertise-routes="]
            end

          if advertise_connector do
            tag = get_connector_tag(pair_id, config)

            domains_str =
              Map.get(config, "advertise_connector_domains") ||
                Map.get(config, :advertise_connector_domains) || ""

            domains =
              String.split(domains_str, [",", "\n"])
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))

            api_key =
              Map.get(config, "ts_api_key") || Map.get(config, :ts_api_key) ||
                Hermit.Vpn.Setting.get_value("tailscale_api_key", "")

            tailnet =
              Map.get(config, "ts_tailnet") || Map.get(config, :ts_tailnet) ||
                Hermit.Vpn.Setting.get_value("tailscale_tailnet", "")

            if api_key != "" and tailnet != "" do
              Logger.info(
                "Pre-updating Tailscale App Connector ACL for domains: #{inspect(domains)}"
              )

              case do_update_app_connector_acl(api_key, tailnet, tag, domains) do
                {:ok, _} ->
                  Logger.info("Tailscale ACL pre-updated successfully.")

                {:error, reason} ->
                  Logger.warning("Failed to pre-update Tailscale ACL: #{inspect(reason)}")
              end
            else
              Logger.warning(
                "Tailscale API credentials not configured. Skipping pre-update of ACL."
              )
            end
          end

          case run_cmd("ip", ts_up_args) do
            {:ok, _} ->
              dns_resolvers = Map.get(config, "dns_resolvers") || Map.get(config, :dns_resolvers)
              dns_mode = Map.get(config, "dns_mode") || Map.get(config, :dns_mode)

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
        socket_path = "/run/tailscaled.#{pair_id}.socket"
        login_server = Map.get(config, :login_server) || Map.get(config, "login_server")

        advertise_exit_node =
          case Map.get(config, :advertise_exit_node) || Map.get(config, "advertise_exit_node") do
            false -> false
            "false" -> false
            nil -> true
            _ -> true
          end

        advertise_connector =
          case Map.get(config, :advertise_connector) || Map.get(config, "advertise_connector") do
            true -> true
            "true" -> true
            _ -> false
          end

        advertise_routes =
          Map.get(config, :advertise_routes) || Map.get(config, "advertise_routes") || ""

        ts_up_args = [
          "netns",
          "exec",
          wg_name,
          "tailscale",
          "--socket=#{socket_path}",
          "up",
          "--reset",
          "--accept-dns=true",
          "--accept-routes=false",
          "--hostname=hermit-node-#{String.replace(pair_id, "_", "-")}",
          "--timeout=30s"
        ]

        ts_up_args =
          if login_server && login_server != "" do
            ts_up_args ++ ["--login-server=#{login_server}"]
          else
            ts_up_args
          end

        ts_up_args =
          if advertise_exit_node do
            ts_up_args ++ ["--advertise-exit-node"]
          else
            ts_up_args ++ ["--advertise-exit-node=false"]
          end

        ts_up_args =
          if advertise_connector do
            tag = get_connector_tag(pair_id, config)
            ts_up_args ++ ["--advertise-connector", "--advertise-tags=#{tag}"]
          else
            ts_up_args ++ ["--advertise-connector=false"]
          end

        ts_up_args =
          if clean_routes(advertise_routes) != "" do
            ts_up_args ++ ["--advertise-routes=#{clean_routes(advertise_routes)}"]
          else
            ts_up_args ++ ["--advertise-routes="]
          end

        case run_cmd("ip", ts_up_args) do
          {:ok, _} ->
            dns_resolvers = Map.get(config, "dns_resolvers") || Map.get(config, :dns_resolvers)
            dns_mode = Map.get(config, "dns_mode") || Map.get(config, :dns_mode)

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
  Approves advertised routes (exit nodes, subnets, app connectors) for a Tailscale node using Tailscale API.
  """
  @impl true
  def approve_exit_node(pair_id) do
    cond do
      mock?() ->
        Logger.info("Mock: Approving Tailscale routes/connector for #{pair_id}")
        {:ok, :approved}

      true ->
        pair =
          case Hermit.Repo.get(Hermit.Vpn.VpnPair, pair_id) do
            nil -> nil
            p -> Hermit.Repo.preload(p, :inbound_profile)
          end

        config = get_inbound_config(pair)

        api_key =
          Map.get(config, "ts_api_key") ||
            (pair && pair.inbound_profile && pair.inbound_profile.config["ts_api_key"]) ||
            Hermit.Vpn.Setting.get_value("tailscale_api_key", "")

        tailnet =
          Map.get(config, "ts_tailnet") ||
            (pair && pair.inbound_profile && pair.inbound_profile.config["ts_tailnet"]) ||
            Hermit.Vpn.Setting.get_value("tailscale_tailnet", "")

        if api_key == "" or tailnet == "" do
          Logger.warning(
            "Tailscale API credentials not configured. Skipping auto-approval and connector ACL updates."
          )

          {:error, :missing_credentials}
        else
          # 1. Handle Routes approval (Exit node or Subnets)
          advertise_exit_node =
            case Map.get(config, "advertise_exit_node") do
              false -> false
              "false" -> false
              nil -> true
              _ -> true
            end

          advertise_routes = Map.get(config, "advertise_routes") || ""

          routes_res =
            if advertise_exit_node or clean_routes(advertise_routes) != "" do
              expected_hostname = "hermit-node-#{String.replace(pair_id, "_", "-")}"
              Logger.info("Starting Tailscale routes approval for #{expected_hostname}")
              do_approve_exit_node(api_key, tailnet, expected_hostname, 5)
            else
              Logger.info(
                "Node #{pair_id} is not advertising any routes. Skipping routes approval."
              )

              {:ok, :skipped}
            end

          # 2. Handle App Connector ACL update
          advertise_connector =
            case Map.get(config, "advertise_connector") do
              true -> true
              "true" -> true
              _ -> false
            end

          tag = get_connector_tag(pair_id, config)

          domains =
            if advertise_connector do
              domains_str =
                Map.get(config, "advertise_connector_domains") ||
                  Map.get(config, :advertise_connector_domains) || ""

              String.split(domains_str, [",", "\n"])
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))
            else
              []
            end

          Logger.info(
            "Updating Tailscale App Connector ACL for domains: #{inspect(domains)} (tag: #{tag})"
          )

          connector_res = do_update_app_connector_acl(api_key, tailnet, tag, domains)

          case {routes_res, connector_res} do
            {{:error, r_err}, {:error, c_err}} -> {:error, {:multiple_errors, r_err, c_err}}
            {{:error, r_err}, _} -> {:error, {:routes_error, r_err}}
            {_, {:error, c_err}} -> {:error, {:connector_error, c_err}}
            _ -> {:ok, :approved}
          end
        end
    end
  end

  defp do_approve_exit_node(_api_key, _tailnet, expected_hostname, 0) do
    Logger.error("Failed to find Tailscale device #{expected_hostname} after multiple retries.")
    {:error, :device_not_found}
  end

  defp do_approve_exit_node(api_key, tailnet, expected_hostname, retries_left) do
    devices_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/devices"

    case Req.get(devices_url, auth: {:basic, "#{api_key}:"}) do
      {:ok, %{status: 200, body: %{"devices" => devices}}} ->
        device =
          Enum.find(devices, fn dev ->
            dev["hostname"] == expected_hostname or
              String.starts_with?(dev["name"] || "", expected_hostname <> ".")
          end)

        if device do
          device_id = device["id"]
          routes_url = "https://api.tailscale.com/api/v2/device/#{device_id}/routes"

          case Req.get(routes_url, auth: {:basic, "#{api_key}:"}) do
            {:ok, %{status: 200, body: %{"advertisedRoutes" => advertised_routes}}} ->
              if advertised_routes != [] do
                Logger.info(
                  "Found advertised routes: #{inspect(advertised_routes)}. Auto-approving..."
                )

                routes_payload = %{routes: advertised_routes}

                case Req.post(routes_url, json: routes_payload, auth: {:basic, "#{api_key}:"}) do
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
                do_approve_exit_node(api_key, tailnet, expected_hostname, retries_left - 1)
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
              ["100.100.100.100", "1.1.1.1", "8.8.8.8"]
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

  @doc """
  Updates the Tailscale ACL to map the specified tag to a list of domains for the App Connector.
  """
  def update_app_connector_acl(pair_id, tag, domains) when is_list(domains) do
    cond do
      mock?() ->
        Logger.info("Mock: Updating Tailscale App Connector ACL for tag #{tag}")
        {:ok, :updated}

      true ->
        pair =
          case Hermit.Repo.get(Hermit.Vpn.VpnPair, pair_id) do
            nil -> nil
            p -> Hermit.Repo.preload(p, :inbound_profile)
          end

        config = get_inbound_config(pair)

        api_key =
          Map.get(config, "ts_api_key") ||
            (pair && pair.inbound_profile && pair.inbound_profile.config["ts_api_key"]) ||
            Hermit.Vpn.Setting.get_value("tailscale_api_key", "")

        tailnet =
          Map.get(config, "ts_tailnet") ||
            (pair && pair.inbound_profile && pair.inbound_profile.config["ts_tailnet"]) ||
            Hermit.Vpn.Setting.get_value("tailscale_tailnet", "")

        if api_key == "" or tailnet == "" do
          Logger.warning(
            "Tailscale API credentials not configured. Skipping App Connector ACL update."
          )

          {:error, :missing_credentials}
        else
          try do
            do_update_app_connector_acl(api_key, tailnet, tag, domains)
          rescue
            e ->
              Logger.error("Exception raised during Tailscale ACL update: #{inspect(e)}")
              {:error, {:exception, e}}
          end
        end
    end
  end

  @doc """
  Queries and parses the tailscale app connectors list directly from the ACL.
  """
  def get_app_connectors(profile) do
    api_key =
      profile.config["ts_api_key"] || Hermit.Vpn.Setting.get_value("tailscale_api_key", "")

    tailnet =
      profile.config["ts_tailnet"] || Hermit.Vpn.Setting.get_value("tailscale_tailnet", "")

    cond do
      mock?() ->
        docker_config = Application.get_env(:hermit, :docker, [])
        connectors = Keyword.get(docker_config, :mock_app_connectors, [])
        {:ok, connectors}

      api_key == "" or tailnet == "" ->
        {:error, :missing_credentials}

      true ->
        acl_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/acl"

        case Req.get(acl_url,
               auth: {:basic, "#{api_key}:"},
               headers: [{"accept", "application/json"}],
               receive_timeout: 4000
             ) do
          {:ok, %{status: 200, body: acl}} ->
            wrapped? = Map.has_key?(acl, "acl")

            acl_map_result =
              if wrapped? do
                acl_str = Map.get(acl, "acl")
                clean_str = clean_hujson(acl_str)

                case Jason.decode(clean_str) do
                  {:ok, parsed} -> {:ok, parsed}
                  {:error, _} -> {:error, :hujson_parse_failed}
                end
              else
                {:ok, acl}
              end

            case acl_map_result do
              {:ok, acl_map} ->
                node_attrs = Map.get(acl_map, "nodeAttrs", [])

                star_attr =
                  Enum.find(node_attrs, fn attr ->
                    targets = Map.get(attr, "target", [])
                    "*" in targets or targets == ["*"]
                  end)

                connectors =
                  if star_attr do
                    app = Map.get(star_attr, "app", %{})
                    Map.get(app, "tailscale.com/app-connectors", [])
                  else
                    []
                  end

                {:ok, connectors}

              {:error, reason} ->
                {:error, reason}
            end

          {:ok, %{status: status, body: body}} ->
            {:error, {:acl_fetch_failed, status, body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Updates the Tailscale ACL for a given tag/domains directly using Profile credentials.
  """
  def update_profile_connector_acl(profile, tag, domains) do
    api_key =
      profile.config["ts_api_key"] || Hermit.Vpn.Setting.get_value("tailscale_api_key", "")

    tailnet =
      profile.config["ts_tailnet"] || Hermit.Vpn.Setting.get_value("tailscale_tailnet", "")

    cond do
      mock?() ->
        Logger.info("Mock: Updating Tailscale ACL for profile tag #{tag}")
        docker_config = Application.get_env(:hermit, :docker, [])
        mock_connectors = Keyword.get(docker_config, :mock_app_connectors, [])

        updated_mock_connectors =
          Enum.map(mock_connectors, fn conn ->
            if tag in Map.get(conn, "connectors", []) or tag == conn["name"] do
              Map.put(conn, "domains", domains)
            else
              conn
            end
          end)

        Application.put_env(
          :hermit,
          :docker,
          Keyword.put(docker_config, :mock_app_connectors, updated_mock_connectors)
        )

        {:ok, :updated}

      api_key == "" or tailnet == "" ->
        {:error, :missing_credentials}

      true ->
        try do
          do_update_app_connector_acl(api_key, tailnet, tag, domains)
        rescue
          e ->
            Logger.error("Exception raised during Tailscale ACL update: #{inspect(e)}")
            {:error, {:exception, e}}
        end
    end
  end

  defp do_update_app_connector_acl(api_key, tailnet, tag, domains) do
    acl_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/acl"

    case Req.get(acl_url,
           auth: {:basic, "#{api_key}:"},
           headers: [{"accept", "application/json"}]
         ) do
      {:ok, %{status: 200, body: acl} = response} ->
        etag =
          case Req.Response.get_header(response, "etag") do
            [val | _] -> val
            _ -> nil
          end

        wrapped? = Map.has_key?(acl, "acl")

        acl_map_result =
          if wrapped? do
            acl_str = Map.get(acl, "acl")
            clean_str = clean_hujson(acl_str)

            case Jason.decode(clean_str) do
              {:ok, parsed} ->
                {:ok, parsed}

              {:error, reason} ->
                Logger.error(
                  "Failed to decode clean HuJSON: #{inspect(reason)}\nCleaned string: #{clean_str}"
                )

                {:error, :hujson_parse_failed}
            end
          else
            {:ok, acl}
          end

        case acl_map_result do
          {:ok, acl_map} ->
            tag = if String.starts_with?(tag, "tag:"), do: tag, else: "tag:#{tag}"
            domains = Enum.map(domains, &String.trim/1) |> Enum.reject(&(&1 == ""))

            if domains == [] and not has_connector_tag?(acl_map, tag) do
              Logger.info("Connector tag #{tag} not present in Tailscale ACL and no domains provided. Skipping ACL update.")
              {:ok, :skipped_no_change}
            else
              updated_acl_map = update_acl_for_app_connector(acl_map, tag, domains)
              hujson_str = "// Hermit App Connector Update\n" <> Jason.encode!(updated_acl_map)

              req_opts =
                if wrapped? do
                  [
                    json: Map.put(acl, "acl", hujson_str),
                    auth: {:basic, "#{api_key}:"},
                    headers: [{"content-type", "application/json"}]
                  ]
                else
                  [
                    body: hujson_str,
                    auth: {:basic, "#{api_key}:"},
                    headers: [{"content-type", "text/plain"}]
                  ]
                end

              req_opts =
                if etag do
                  Keyword.put(req_opts, :headers, req_opts[:headers] ++ [{"if-match", etag}])
                else
                  req_opts
                end

              case Req.post(acl_url, req_opts) do
                {:ok, %{status: 200}} ->
                  Logger.info("Successfully updated Tailscale ACL for App Connector tag #{tag}")
                  {:ok, :updated}

                {:ok, %{status: status, body: body}} ->
                  Logger.error("Failed to update Tailscale ACL (HTTP #{status}): #{inspect(body)}")
                  {:error, {:acl_update_failed, status, body}}

                {:error, reason} ->
                  Logger.error("Failed to call Tailscale ACL update API: #{inspect(reason)}")
                  {:error, reason}
              end
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to fetch Tailscale ACL (HTTP #{status}): #{inspect(body)}")
        {:error, {:acl_fetch_failed, status, body}}

      {:error, reason} ->
        Logger.error("Failed to call Tailscale ACL fetch API: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def update_acl_for_app_connector(acl_map, tag, domains) do
    tag = if String.starts_with?(tag, "tag:"), do: tag, else: "tag:#{tag}"

    if domains == [] do
      tag_owners = Map.get(acl_map, "tagOwners", %{})
      updated_tag_owners = Map.delete(tag_owners, tag)

      node_attrs = Map.get(acl_map, "nodeAttrs", [])
      updated_node_attrs = update_node_attrs(node_attrs, tag, [])

      auto_approvers = Map.get(acl_map, "autoApprovers", %{})
      routes = Map.get(auto_approvers, "routes", %{})
      existing_v4 = Map.get(routes, "0.0.0.0/0", [])
      existing_v6 = Map.get(routes, "::/0", [])
      updated_v4 = List.delete(existing_v4, tag)
      updated_v6 = List.delete(existing_v6, tag)

      updated_routes =
        routes
        |> Map.put("0.0.0.0/0", updated_v4)
        |> Map.put("::/0", updated_v6)

      updated_auto_approvers = Map.put(auto_approvers, "routes", updated_routes)

      grants = Map.get(acl_map, "grants", [])
      updated_grants = Enum.reject(grants, fn grant -> Map.get(grant, "dst") == [tag] end)

      acl_map
      |> Map.put("tagOwners", updated_tag_owners)
      |> Map.put("nodeAttrs", updated_node_attrs)
      |> Map.put("autoApprovers", updated_auto_approvers)
      |> Map.put("grants", updated_grants)
    else
      tag_owners = Map.get(acl_map, "tagOwners", %{})

      updated_tag_owners =
        if Map.has_key?(tag_owners, tag) do
          tag_owners
        else
          Map.put(tag_owners, tag, ["autogroup:admin"])
        end

      node_attrs = Map.get(acl_map, "nodeAttrs", [])
      updated_node_attrs = update_node_attrs(node_attrs, tag, domains)

      auto_approvers = Map.get(acl_map, "autoApprovers", %{})
      routes = Map.get(auto_approvers, "routes", %{})
      existing_v4 = Map.get(routes, "0.0.0.0/0", [])
      existing_v6 = Map.get(routes, "::/0", [])
      updated_v4 = if tag in existing_v4, do: existing_v4, else: existing_v4 ++ [tag]
      updated_v6 = if tag in existing_v6, do: existing_v6, else: existing_v6 ++ [tag]

      updated_routes =
        routes
        |> Map.put("0.0.0.0/0", updated_v4)
        |> Map.put("::/0", updated_v6)

      updated_auto_approvers = Map.put(auto_approvers, "routes", updated_routes)

      grants = Map.get(acl_map, "grants", [])
      updated_grants = update_grants(grants, tag)

      acl_map
      |> Map.put("tagOwners", updated_tag_owners)
      |> Map.put("nodeAttrs", updated_node_attrs)
      |> Map.put("autoApprovers", updated_auto_approvers)
      |> Map.put("grants", updated_grants)
    end
  end

  defp has_connector_tag?(acl_map, tag) do
    tag_owners = Map.get(acl_map, "tagOwners", %{})
    has_tag_owner? = Map.has_key?(tag_owners, tag)

    node_attrs = Map.get(acl_map, "nodeAttrs", [])
    has_node_attr? =
      Enum.any?(node_attrs, fn attr ->
        app = Map.get(attr, "app", %{})
        connectors_list = Map.get(app, "tailscale.com/app-connectors", [])
        Enum.any?(connectors_list, fn conn ->
          tag in Map.get(conn, "connectors", [])
        end)
      end)

    auto_approvers = Map.get(acl_map, "autoApprovers", %{})
    routes = Map.get(auto_approvers, "routes", %{})
    has_auto_approve? =
      Enum.any?(routes, fn {_route, tags} ->
        is_list(tags) and tag in tags
      end)

    grants = Map.get(acl_map, "grants", [])
    has_grant? =
      Enum.any?(grants, fn grant ->
        tag in Map.get(grant, "dst", [])
      end)

    has_tag_owner? or has_node_attr? or has_auto_approve? or has_grant?
  end

  defp update_node_attrs(node_attrs, tag, domains) do
    connector_name = "hermit-connector-#{String.replace(tag, "tag:", "")}"

    target_star_index =
      Enum.find_index(node_attrs, fn attr ->
        targets = Map.get(attr, "target", [])
        targets == ["*"] or "*" in targets
      end)

    if target_star_index do
      attr = Enum.at(node_attrs, target_star_index)
      app = Map.get(attr, "app", %{})
      connectors_list = Map.get(app, "tailscale.com/app-connectors", [])

      updated_connectors_list =
        if Enum.any?(connectors_list, fn conn -> tag in Map.get(conn, "connectors", []) end) do
          if domains == [] do
            Enum.reject(connectors_list, fn conn -> tag in Map.get(conn, "connectors", []) end)
          else
            Enum.map(connectors_list, fn conn ->
              if tag in Map.get(conn, "connectors", []) do
                Map.put(conn, "domains", domains)
              else
                conn
              end
            end)
          end
        else
          if domains == [] do
            connectors_list
          else
            new_connector = %{
              "name" => connector_name,
              "connectors" => [tag],
              "domains" => domains
            }

            connectors_list ++ [new_connector]
          end
        end

      updated_connectors_list = cleanup_other_connectors(updated_connectors_list, tag, domains)
      updated_app = Map.put(app, "tailscale.com/app-connectors", updated_connectors_list)
      updated_attr = Map.put(attr, "app", updated_app)
      List.replace_at(node_attrs, target_star_index, updated_attr)
    else
      if domains == [] do
        node_attrs
      else
        new_attr = %{
          "target" => ["*"],
          "app" => %{
            "tailscale.com/app-connectors" => [
              %{
                "name" => connector_name,
                "connectors" => [tag],
                "domains" => domains
              }
            ]
          }
        }

        node_attrs ++ [new_attr]
      end
    end
  end

  defp cleanup_other_connectors(connectors, _current_tag, []), do: connectors

  defp cleanup_other_connectors(connectors, current_tag, domains) do
    domains_down = Enum.map(domains, &String.downcase/1)

    connectors
    |> Enum.map(fn conn ->
      if current_tag not in Map.get(conn, "connectors", []) do
        existing_domains = Map.get(conn, "domains", [])

        updated_domains =
          Enum.reject(existing_domains, fn d -> String.downcase(d) in domains_down end)

        Map.put(conn, "domains", updated_domains)
      else
        conn
      end
    end)
    |> Enum.reject(fn conn ->
      Map.get(conn, "domains", []) == [] and current_tag not in Map.get(conn, "connectors", [])
    end)
  end

  defp update_grants(grants, tag) do
    existing_grant_index =
      Enum.find_index(grants, fn grant ->
        Map.get(grant, "src") == ["autogroup:member"] and
          Map.get(grant, "dst") == [tag]
      end)

    if existing_grant_index do
      grant = Enum.at(grants, existing_grant_index)
      ip_list = Map.get(grant, "ip", [])
      updated_ip = ip_list
      updated_ip = if "tcp:53" in updated_ip, do: updated_ip, else: updated_ip ++ ["tcp:53"]
      updated_ip = if "udp:53" in updated_ip, do: updated_ip, else: updated_ip ++ ["udp:53"]
      updated_grant = Map.put(grant, "ip", updated_ip)
      List.replace_at(grants, existing_grant_index, updated_grant)
    else
      new_grant = %{
        "src" => ["autogroup:member"],
        "dst" => [tag],
        "ip" => ["tcp:53", "udp:53"]
      }

      grants ++ [new_grant]
    end
  end

  def clean_hujson(str) when is_binary(str) do
    str
    |> String.to_charlist()
    |> clean_hujson_chars(false, false, false, [])
    |> List.to_string()
  end

  defp next_char_is_closing_bracket?([char | rest]) when char in [?\s, ?\t, ?\n, ?\r] do
    next_char_is_closing_bracket?(rest)
  end

  defp next_char_is_closing_bracket?([char | _]) when char in [?], ?}] do
    true
  end

  defp next_char_is_closing_bracket?(_) do
    false
  end

  defp clean_hujson_chars([?*, ?/ | rest], _in_string, false, true, acc) do
    clean_hujson_chars(rest, false, false, false, acc)
  end

  defp clean_hujson_chars([_char | rest], in_string, false, true, acc) do
    clean_hujson_chars(rest, in_string, false, true, acc)
  end

  defp clean_hujson_chars([?\n | rest], _in_string, true, false, acc) do
    clean_hujson_chars(rest, false, false, false, [?\n | acc])
  end

  defp clean_hujson_chars([_char | rest], in_string, true, false, acc) do
    clean_hujson_chars(rest, in_string, true, false, acc)
  end

  defp clean_hujson_chars([?\\, ?\" | rest], true, false, false, acc) do
    clean_hujson_chars(rest, true, false, false, [?\", ?\\ | acc])
  end

  defp clean_hujson_chars([?\" | rest], true, false, false, acc) do
    clean_hujson_chars(rest, false, false, false, [?\" | acc])
  end

  defp clean_hujson_chars([char | rest], true, false, false, acc) do
    clean_hujson_chars(rest, true, false, false, [char | acc])
  end

  defp clean_hujson_chars([?/, ?* | rest], false, false, false, acc) do
    clean_hujson_chars(rest, false, false, true, acc)
  end

  defp clean_hujson_chars([?/, ?/ | rest], false, false, false, acc) do
    clean_hujson_chars(rest, false, true, false, acc)
  end

  defp clean_hujson_chars([?# | rest], false, false, false, acc) do
    clean_hujson_chars(rest, false, true, false, acc)
  end

  defp clean_hujson_chars([?\" | rest], false, false, false, acc) do
    clean_hujson_chars(rest, true, false, false, [?\" | acc])
  end

  defp clean_hujson_chars([?, | rest], false, false, false, acc) do
    if next_char_is_closing_bracket?(rest) do
      clean_hujson_chars(rest, false, false, false, acc)
    else
      clean_hujson_chars(rest, false, false, false, [?, | acc])
    end
  end

  defp clean_hujson_chars([char | rest], false, false, false, acc) do
    clean_hujson_chars(rest, false, false, false, [char | acc])
  end

  defp clean_hujson_chars([], _in_string, _in_line_comment, _in_block_comment, acc) do
    Enum.reverse(acc)
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

  defp get_connector_tag(pair_id, config) do
    tag =
      Map.get(config, "advertise_connector_tag") ||
        Map.get(config, :advertise_connector_tag)

    default_tag = "tag:connector-#{String.replace(pair_id, "_", "-")}"

    resolved_tag =
      if is_binary(tag) and String.trim(tag) != "" do
        tag = String.trim(tag)
        normalized_id = String.replace(pair_id, "_", "-")

        case Regex.run(~r/^tag:connector-(.+)$/, tag) do
          [_, other_id] when other_id != normalized_id ->
            default_tag

          _ ->
            tag
        end
      else
        default_tag
      end

    if String.starts_with?(resolved_tag, "tag:"), do: resolved_tag, else: "tag:#{resolved_tag}"
  end

  defp get_inbound_config(pair) do
    cond do
      pair && pair.inbound_config && map_size(pair.inbound_config) > 0 ->
        pair.inbound_config

      pair && pair.inbound_profile ->
        pair.inbound_profile.config || %{}

      true ->
        %{}
    end
  end

  defp clean_routes(nil), do: ""

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
end
