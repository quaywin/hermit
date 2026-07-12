defmodule Hermit.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    enable_host_ip_forwarding()

    children = [
      Hermit.Repo,
      {Phoenix.PubSub, name: Hermit.PubSub},
      {Registry, keys: :unique, name: Hermit.Vpn.Registry},
      {Task.Supervisor, name: Hermit.Dns.TaskSupervisor},
      {Hermit.Vpn.DynamicSupervisor, []},
      {Hermit.Dns.BlocklistLoader, []},
      {Hermit.Dns.Telemetry, []},
      {Hermit.Vpn.DnsDeviceResolver, []},
      {Hermit.Vpn.DnsSupervisor, []},
      HermitWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hermit.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        run_migrations()
        Hermit.Dns.Telemetry.restore_metrics()
        seed_default_local_profile()
        boot_vpn_pairs()
        boot_dns_nodes()
        {:ok, pid}

      other ->
        other
    end
  end

  defp run_migrations do
    path = Application.app_dir(:hermit, "priv/repo/migrations")
    Ecto.Migrator.run(Hermit.Repo, path, :up, all: true)
  rescue
    e ->
      IO.inspect(e, label: "Failed to run SQLite migrations on startup")
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
      IO.inspect(e, label: "Failed to seed default local outbound profile")
  end

  defp boot_dns_nodes do
    if Application.get_env(:hermit, :boot_persisted_pairs, true) do
      Task.start(fn ->
        try do
          inbound_profiles =
            Hermit.Repo.all(Hermit.Vpn.InboundProfile) |> Hermit.Repo.preload(:dns_profile)

          Enum.each(inbound_profiles, fn profile ->
            if profile.type == "tailscale" && profile.dns_profile && profile.dns_profile.enabled do
              case Hermit.Vpn.DnsSupervisor.start_dns(profile.id) do
                {:ok, _} -> :ok
                _ -> :error
              end
            end
          end)
        rescue
          e ->
            IO.inspect(e, label: "Error booting persisted DNS nodes")
        end
      end)
    else
      :ok
    end
  end

  defp boot_vpn_pairs do
    if Application.get_env(:hermit, :boot_persisted_pairs, true) do
      Task.start(fn ->
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
                  IO.inspect(error, label: "Failed to boot VPN pair #{pair.pair_id} on startup")
              end
            end
          end)
        rescue
          e ->
            IO.inspect(e, label: "Error booting persisted VPN pairs")
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
      IO.puts("Ensuring IP forwarding is enabled on the host...")

      try do
        System.cmd("sysctl", ["-w", "net.ipv4.ip_forward=1"])
        System.cmd("sysctl", ["-w", "net.ipv6.conf.all.forwarding=1"])
        System.cmd("sysctl", ["-w", "net.ipv4.conf.all.rp_filter=2"])
        System.cmd("sysctl", ["-w", "net.ipv4.conf.default.rp_filter=2"])

        # Setup host network rules using nftables
        setup_nftables_host()
      rescue
        e ->
          IO.inspect(e,
            label:
              "Warning: Failed to enable host IP forwarding (ensure container has privileged/host permissions)"
          )
      end
    end
  end

  defp setup_nftables_host do
    try do
      # 1. Ensure table exists
      run_nft(["add", "table", "inet", "hermit_host"])
      # 2. Flush to prevent duplicate rules on restart
      run_nft(["flush", "table", "inet", "hermit_host"])

      # 3. Create chains
      run_nft([
        "add",
        "chain",
        "inet",
        "hermit_host",
        "input",
        "{ type filter hook input priority filter ; }"
      ])

      run_nft([
        "add",
        "chain",
        "inet",
        "hermit_host",
        "forward",
        "{ type filter hook forward priority filter ; }"
      ])

      run_nft([
        "add",
        "chain",
        "inet",
        "hermit_host",
        "postrouting",
        "{ type nat hook postrouting priority srcnat ; }"
      ])

      # 4. Input rules for virtual interfaces (dns_h*, loc*, vh*)
      run_nft(["add", "rule", "inet", "hermit_host", "input", "iifname", "dns_h*", "accept"])
      run_nft(["add", "rule", "inet", "hermit_host", "input", "iifname", "loc*", "accept"])
      run_nft(["add", "rule", "inet", "hermit_host", "input", "iifname", "vh*", "accept"])

      # 5. Forwarding rules for Tailscale range
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
      ])

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
      ])

      # MSS clamping to prevent MTU issues
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
      ])

      # 6. Nat masquerade for Tailscale range
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
      ])

      :ok
    rescue
      e ->
        IO.inspect(e, label: "Warning: Failed to setup nftables host rules")
        {:error, e}
    end
  end

  defp run_nft(args) do
    case System.cmd("nft", args) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {code, output}}
    end
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end
end
