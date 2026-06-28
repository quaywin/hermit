defmodule Hermit.Vpn.InboundProfile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "inbound_profiles" do
    field(:name, :string)
    field(:type, :string)
    field(:config, :map, default: %{})

    timestamps()
  end

  @doc false
  def changeset(inbound_profile, attrs) do
    inbound_profile
    |> cast(attrs, [:name, :type, :config])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, ["tailscale", "headscale", "zerotier", "proxy"])
    |> validate_config()
  end

  defp validate_config(changeset) do
    type = get_field(changeset, :type)
    config = get_field(changeset, :config) || %{}

    case type do
      "tailscale" ->
        # ts_auth_key is optional since it falls back to global settings, but config should be a map
        if is_map(config) do
          changeset
        else
          add_error(changeset, :config, "must be a map")
        end

      "headscale" ->
        ts_auth_key = Map.get(config, "ts_auth_key") || Map.get(config, :ts_auth_key)
        login_server = Map.get(config, "login_server") || Map.get(config, :login_server)

        changeset =
          if is_nil(ts_auth_key) || ts_auth_key == "" do
            add_error(changeset, :config, "Headscale requires ts_auth_key")
          else
            changeset
          end

        if is_nil(login_server) || login_server == "" do
          add_error(changeset, :config, "Headscale requires login_server")
        else
          changeset
        end

      "zerotier" ->
        network_id = Map.get(config, "network_id") || Map.get(config, :network_id)

        if is_nil(network_id) || network_id == "" do
          add_error(changeset, :config, "ZeroTier requires network_id")
        else
          changeset
        end

      "proxy" ->
        port = Map.get(config, "port") || Map.get(config, :port)

        if is_nil(port) || port == "" do
          add_error(changeset, :config, "Proxy requires port")
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
