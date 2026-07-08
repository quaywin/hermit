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
      {Hermit.Vpn.DnsLogReceiver, []},
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
          inbound_profiles = Hermit.Repo.all(Hermit.Vpn.InboundProfile) |> Hermit.Repo.preload(:dns_profile)

          Enum.each(inbound_profiles, fn profile ->
            if profile.dns_profile && profile.dns_profile.enabled do
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

        # Ensure NAT and forwarding rules for Tailscale range are present on host
        ensure_nat_rule(["POSTROUTING", "-s", "100.64.0.0/10", "-j", "MASQUERADE"])
        ensure_iptables_rule(["FORWARD", "-s", "100.64.0.0/10", "-j", "ACCEPT"])
        ensure_iptables_rule(["FORWARD", "-d", "100.64.0.0/10", "-j", "ACCEPT"])

        # Ensure incoming traffic from virtual interfaces is allowed in host INPUT chain
        ensure_iptables_rule(["INPUT", "-i", "dns_h_+", "-j", "ACCEPT"])
        ensure_iptables_rule(["INPUT", "-i", "loc_+", "-j", "ACCEPT"])
        ensure_iptables_rule(["INPUT", "-i", "vh_+", "-j", "ACCEPT"])

        # Clamp TCP MSS to path MTU to prevent MTU issues in cloud environments like GCP/AWS
        ensure_iptables_rule("mangle", [
          "FORWARD",
          "-p",
          "tcp",
          "--tcp-flags",
          "SYN,RST",
          "SYN",
          "-j",
          "TCPMSS",
          "--clamp-mss-to-pmtu"
        ])
      rescue
        e ->
          IO.inspect(e,
            label:
              "Warning: Failed to enable host IP forwarding (ensure container has privileged/host permissions)"
          )
      end
    end
  end

  defp ensure_iptables_rule(table, args) do
    case System.cmd("iptables", ["-t", table, "-C" | args]) do
      {_, 0} -> :ok
      _ -> System.cmd("iptables", ["-t", table, "-I" | args])
    end
  end

  defp ensure_iptables_rule(args) do
    ensure_iptables_rule("filter", args)
  end

  defp ensure_nat_rule(args) do
    case System.cmd("iptables", ["-t", "nat", "-C" | args]) do
      {_, 0} -> :ok
      _ -> System.cmd("iptables", ["-t", "nat", "-I" | args])
    end
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end
end
