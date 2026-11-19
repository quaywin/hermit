defmodule Hermit.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    enable_host_ip_forwarding()
    clean_stale_netns()

    run_migrations()

    dns_supervisor = %{
      id: Hermit.Dns.Supervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             {Task.Supervisor, name: Hermit.Dns.TaskSupervisor},
             {Hermit.Dns.BlocklistLoader, []},
             {Hermit.Dns.Telemetry, []},
             {Hermit.Vpn.DnsDeviceResolver, []},
             {Hermit.Vpn.DnsDdnsResolver, []},
             {Hermit.Dns.Port53Server, []}
           ],
           [strategy: :one_for_one, name: Hermit.Dns.Supervisor]
         ]}
    }

    vpn_supervisor = %{
      id: Hermit.Vpn.Supervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             {Registry, keys: :unique, name: Hermit.Vpn.Registry},
             {Hermit.Vpn.SubnetPool, []},
             {Hermit.Vpn.PortAllocator, []},
             {Hermit.Vpn.DynamicSupervisor, []},
             {Hermit.Vpn.DnsSupervisor, []},
             {Task.Supervisor, name: Hermit.Vpn.SniProxy.TaskSupervisor},
             {Hermit.Vpn.SniProxy.Server, []}
           ],
           [strategy: :rest_for_one, name: Hermit.Vpn.Supervisor]
         ]}
    }

    children = [
      Hermit.Repo,
      {Phoenix.PubSub, name: Hermit.PubSub},
      {Task.Supervisor, name: Hermit.BootTaskSupervisor},
      dns_supervisor,
      vpn_supervisor,
      {Hermit.Updater, []},
      HermitWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hermit.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Hermit.Dns.Telemetry.restore_metrics()
        seed_default_local_profile()
        Hermit.Vpn.SniProxy.sync_all_routes()
        boot_vpn_pairs()
        boot_dns_nodes()
        {:ok, pid}

      other ->
        other
    end
  end

  defp run_migrations do
    path = Application.app_dir(:hermit, "priv/repo/migrations")

    case Ecto.Migrator.with_repo(Hermit.Repo, &Ecto.Migrator.run(&1, path, :up, all: true)) do
      {:ok, _, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to run SQLite migrations on startup: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.error("Failed to run SQLite migrations on startup: #{inspect(e)}")
  end

  defp seed_default_local_profile do
    case Hermit.Repo.get_by(Hermit.Vpn.OutboundProfile, type: "local") do
      nil ->
        %Hermit.Vpn.OutboundProfile{}
        |> Hermit.Vpn.OutboundProfile.changeset(%{
          name: "Host Local Network",
          type: "local",
          config: %{}
        })
        |> Hermit.Repo.insert()

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Failed to seed default local outbound profile: #{inspect(e)}")
  end

  defp boot_dns_nodes do
    if Application.get_env(:hermit, :boot_persisted_pairs, true) do
      Task.Supervisor.start_child(Hermit.BootTaskSupervisor, fn ->
        try do
          endpoints = Hermit.Repo.all(Hermit.Vpn.DnsEndpoint)

          Enum.each(endpoints, fn endpoint ->
            if endpoint.enabled do
              case Hermit.Vpn.DnsSupervisor.start_dns(endpoint.id, endpoint.inbound_profile_id) do
                {:ok, _} ->
                  :ok

                error ->
                  Logger.warning(
                    "Failed to boot DNS endpoint #{endpoint.id} on startup: #{inspect(error)}"
                  )

                  try do
                    endpoint
                    |> Ecto.Changeset.change(%{enabled: false})
                    |> Hermit.Repo.update()
                  rescue
                    _ -> :ok
                  end
              end

              # Stagger startup of multiple pairs by 500ms to avoid CPU spike and API throttling
              Process.sleep(500)
            end
          end)
        rescue
          e ->
            Logger.error("Error booting persisted DNS endpoints: #{inspect(e)}")
        end
      end)
    else
      :ok
    end
  end

  defp boot_vpn_pairs do
    if Application.get_env(:hermit, :boot_persisted_pairs, true) do
      Task.Supervisor.start_child(Hermit.BootTaskSupervisor, fn ->
        try do
          pairs = Hermit.Repo.all(Hermit.Vpn.VpnPair)

          Enum.each(pairs, fn pair ->
            if pair.status != "stopped" do
              case Hermit.Vpn.DynamicSupervisor.start_pair(%{
                     id: pair.pair_id,
                     inbound_profile_id: pair.inbound_profile_id,
                     outbound_profile_id: pair.outbound_profile_id
                   }) do
                {:ok, _pid} ->
                  :ok

                error ->
                  Logger.warning(
                    "Failed to boot VPN pair #{pair.pair_id} on startup: #{inspect(error)}"
                  )

                  try do
                    pair
                    |> Ecto.Changeset.change(%{status: "error"})
                    |> Hermit.Repo.update()
                  rescue
                    _ -> :ok
                  end
              end

              # Stagger startup of multiple pairs by 500ms to avoid CPU spike and API throttling
              Process.sleep(500)
            end
          end)

          # Re-sync SNI Proxy routes once persisted VPN pairs have started
          Hermit.Vpn.SniProxy.sync_all_routes()
        rescue
          e ->
            Logger.error("Error booting persisted VPN pairs: #{inspect(e)}")
        end
      end)
    else
      :ok
    end
  end

  # Tell the endpoint to update the configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HermitWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp enable_host_ip_forwarding do
    if :os.type() == {:unix, :linux} and not mock?() do
      Logger.info("Ensuring IP forwarding is enabled on the host...")

      try do
        System.cmd("sysctl", ["-w", "net.ipv4.ip_forward=1"])
        System.cmd("sysctl", ["-w", "net.ipv6.conf.all.forwarding=1"])
        System.cmd("sysctl", ["-w", "net.ipv4.conf.all.rp_filter=2"])
        System.cmd("sysctl", ["-w", "net.ipv4.conf.default.rp_filter=2"])

        # Setup host network rules using nftables (fallback to iptables only if nftables fails)
        case setup_nftables_host() do
          :ok ->
            :ok

          _ ->
            setup_iptables_host()
        end
      rescue
        e ->
          Logger.warning(
            "Failed to enable host IP forwarding (ensure container has privileged/host permissions): #{inspect(e)}"
          )
      end
    end
  end

  defp setup_nftables_host do
    http_port = Hermit.Vpn.SniProxy.Server.http_port()
    https_port = Hermit.Vpn.SniProxy.Server.https_port()

    try do
      script = """
      add table inet hermit_host
      flush table inet hermit_host
      add chain inet hermit_host prerouting { type nat hook prerouting priority dstnat ; }
      add chain inet hermit_host input { type filter hook input priority filter ; }
      add chain inet hermit_host forward { type filter hook forward priority filter ; }
      add chain inet hermit_host postrouting { type nat hook postrouting priority srcnat ; }
      add rule inet hermit_host prerouting ip daddr 100.64.0.0/10 tcp dport 80 redirect to :#{http_port}
      add rule inet hermit_host prerouting ip daddr 100.64.0.0/10 tcp dport 443 redirect to :#{https_port}
      add rule inet hermit_host input iifname "dns_h*" accept
      add rule inet hermit_host input iifname "loc*" accept
      add rule inet hermit_host input iifname "vh*" accept
      add rule inet hermit_host forward ip saddr 100.64.0.0/10 accept
      add rule inet hermit_host forward ip daddr 100.64.0.0/10 accept
      add rule inet hermit_host forward tcp flags syn tcp option maxseg size set rt mtu
      add rule inet hermit_host postrouting ip saddr 100.64.0.0/10 masquerade
      """

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "hermit_host_#{System.unique_integer([:positive])}.conf"
        )

      try do
        File.write!(tmp_path, script)

        case System.cmd("nft", ["-f", tmp_path], stderr_to_stdout: true) do
          {_, 0} ->
            :ok

          {error_output, code} ->
            Logger.warning(
              "nft -f batch failed (#{code}), falling back to sequential: #{error_output}"
            )

            fallback_nftables_host()
        end
      after
        File.rm(tmp_path)
      end
    rescue
      e ->
        Logger.warning("Failed to setup nftables host rules: #{inspect(e)}")
        {:error, e}
    end
  end

  defp fallback_nftables_host do
    http_port = Hermit.Vpn.SniProxy.Server.http_port()
    https_port = Hermit.Vpn.SniProxy.Server.https_port()

    with {:ok, _} <- run_nft(["add", "table", "inet", "hermit_host"]),
         {:ok, _} <- run_nft(["flush", "table", "inet", "hermit_host"]),
         {:ok, _} <-
           run_nft([
             "add",
             "chain",
             "inet",
             "hermit_host",
             "prerouting",
             "{ type nat hook prerouting priority dstnat ; }"
           ]),
         {:ok, _} <-
           run_nft([
             "add",
             "rule",
             "inet",
             "hermit_host",
             "prerouting",
             "ip",
             "daddr",
             "100.64.0.0/10",
             "tcp",
             "dport",
             "80",
             "redirect",
             "to",
             ":#{http_port}"
           ]),
         {:ok, _} <-
           run_nft([
             "add",
             "rule",
             "inet",
             "hermit_host",
             "prerouting",
             "ip",
             "daddr",
             "100.64.0.0/10",
             "tcp",
             "dport",
             "443",
             "redirect",
             "to",
             ":#{https_port}"
           ]),
         {:ok, _} <-
           run_nft([
             "add",
             "chain",
             "inet",
             "hermit_host",
             "input",
             "{ type filter hook input priority filter ; }"
           ]),
         {:ok, _} <-
           run_nft([
             "add",
             "chain",
             "inet",
             "hermit_host",
             "forward",
             "{ type filter hook forward priority filter ; }"
           ]),
         {:ok, _} <-
           run_nft([
             "add",
             "chain",
             "inet",
             "hermit_host",
             "postrouting",
             "{ type nat hook postrouting priority srcnat ; }"
           ]),
         {:ok, _} <-
           run_nft(["add", "rule", "inet", "hermit_host", "input", "iifname", "dns_h*", "accept"]),
         {:ok, _} <-
           run_nft(["add", "rule", "inet", "hermit_host", "input", "iifname", "loc*", "accept"]),
         {:ok, _} <-
           run_nft(["add", "rule", "inet", "hermit_host", "input", "iifname", "vh*", "accept"]),
         {:ok, _} <-
           run_nft([
             "add",
             "rule",
             "inet",
             "hermit_host",
             "forward",
             "ip",
             "saddr",
             "100.64.0.0/10",
             "accept"
           ]),
         {:ok, _} <-
           run_nft([
             "add",
             "rule",
             "inet",
             "hermit_host",
             "forward",
             "ip",
             "daddr",
             "100.64.0.0/10",
             "accept"
           ]),
         {:ok, _} <-
           run_nft([
             "add",
             "rule",
             "inet",
             "hermit_host",
             "forward",
             "tcp",
             "flags",
             "syn",
             "tcp",
             "option",
             "maxseg",
             "size",
             "set",
             "rt",
             "mtu"
           ]),
         {:ok, _} <-
           run_nft([
             "add",
             "rule",
             "inet",
             "hermit_host",
             "postrouting",
             "ip",
             "saddr",
             "100.64.0.0/10",
             "masquerade"
           ]) do
      :ok
    end
  end

  defp run_nft(args) do
    case System.cmd("nft", args) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {code, output}}
    end
  end

  def setup_iptables_host do
    interfaces = ["dns_h+", "loc+", "vh+", "wg+"]
    http_port = Hermit.Vpn.SniProxy.Server.http_port()
    https_port = Hermit.Vpn.SniProxy.Server.https_port()

    if System.find_executable("iptables") do
      try do
        Enum.each(interfaces, fn iface ->
          ensure_iptables_rule("iptables", ["INPUT", "-i", iface, "-j", "ACCEPT"])
          ensure_iptables_rule("iptables", ["FORWARD", "-i", iface, "-j", "ACCEPT"])
          ensure_iptables_rule("iptables", ["FORWARD", "-o", iface, "-j", "ACCEPT"])
        end)

        ensure_iptables_nat_rule("iptables", [
          "PREROUTING",
          "-d",
          "100.64.0.0/10",
          "-p",
          "tcp",
          "--dport",
          "80",
          "-j",
          "REDIRECT",
          "--to-ports",
          to_string(http_port)
        ])

        ensure_iptables_nat_rule("iptables", [
          "PREROUTING",
          "-d",
          "100.64.0.0/10",
          "-p",
          "tcp",
          "--dport",
          "443",
          "-j",
          "REDIRECT",
          "--to-ports",
          to_string(https_port)
        ])
      rescue
        e ->
          Logger.warning("Failed to setup iptables host rules: #{inspect(e)}")
      end
    end

    if System.find_executable("ip6tables") do
      try do
        Enum.each(interfaces, fn iface ->
          ensure_iptables_rule("ip6tables", ["INPUT", "-i", iface, "-j", "ACCEPT"])
          ensure_iptables_rule("ip6tables", ["FORWARD", "-i", iface, "-j", "ACCEPT"])
          ensure_iptables_rule("ip6tables", ["FORWARD", "-o", iface, "-j", "ACCEPT"])
        end)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp ensure_iptables_nat_rule(binary, [chain | rest]) do
    case System.cmd(binary, ["-t", "nat", "-C", chain | rest], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        System.cmd(binary, ["-t", "nat", "-I", chain, "1" | rest], stderr_to_stdout: true)
        :ok
    end
  end

  defp ensure_iptables_rule(binary, [chain | rest]) do
    case System.cmd(binary, ["-C", chain | rest], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        System.cmd(binary, ["-I", chain, "1" | rest], stderr_to_stdout: true)
        :ok
    end
  end

  defp mock?, do: Hermit.mock?()

  defp clean_stale_netns do
    if :os.type() == {:unix, :linux} and not mock?() do
      Logger.info("Cleaning up stale network namespaces...")
      netns_dir = "/var/run/netns"

      if File.exists?(netns_dir) do
        case File.ls(netns_dir) do
          {:ok, files} ->
            Enum.each(files, fn file ->
              if String.starts_with?(file, "hermit_") do
                _ = System.cmd("ip", ["netns", "del", file], stderr_to_stdout: true)
                _ = File.rm(Path.join(netns_dir, file))
              end
            end)

          _ ->
            :ok
        end
      end
    end
  end
end
