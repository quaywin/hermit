defmodule Hermit.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Hermit.Repo,
      {Phoenix.PubSub, name: Hermit.PubSub},
      {Registry, keys: :unique, name: Hermit.Vpn.Registry},
      {Hermit.Vpn.DynamicSupervisor, []},
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HermitWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
