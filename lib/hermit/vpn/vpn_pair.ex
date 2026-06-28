defmodule Hermit.Vpn.VpnPair do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:pair_id, :string, autogenerate: false}
  schema "vpn_pairs" do
    field(:ts_auth_key, :string)
    field(:wg_config, :string)
    field(:inbound_type, :string, default: "tailscale")
    field(:inbound_config, :map)
    field(:outbound_type, :string, default: "wireguard")
    field(:outbound_config, :map)
    field(:status, :string, default: "running")
    field(:wg_status, :string, default: "stopped")
    field(:ts_status, :string, default: "stopped")
    field(:wg_error_reason, :string)
    field(:ts_error_reason, :string)
    field(:started_at, :integer)

    timestamps()
  end

  def changeset(vpn_pair, attrs) do
    vpn_pair
    |> cast(attrs, [
      :pair_id,
      :ts_auth_key,
      :wg_config,
      :inbound_type,
      :inbound_config,
      :outbound_type,
      :outbound_config,
      :status,
      :wg_status,
      :ts_status,
      :wg_error_reason,
      :ts_error_reason,
      :started_at
    ])
    |> validate_required([:pair_id, :wg_config])
    |> validate_format(:pair_id, ~r/^[a-z0-9_]+$/,
      message: "must contain only lowercase letters, numbers, and underscores"
    )
    |> put_modular_configs()
  end

  defp put_modular_configs(changeset) do
    changeset
    |> put_inbound_config()
    |> put_outbound_config()
  end

  defp put_inbound_config(changeset) do
    ts_auth_key = get_field(changeset, :ts_auth_key)
    existing_inbound = get_field(changeset, :inbound_config) || %{}

    login_server =
      case get_change(changeset, :inbound_config) do
        %{"login_server" => ls} -> ls
        %{login_server: ls} -> ls
        _ -> Map.get(existing_inbound, "login_server") || Map.get(existing_inbound, :login_server)
      end

    inbound_config = %{
      "ts_auth_key" => ts_auth_key,
      "login_server" => login_server
    }

    put_change(changeset, :inbound_config, inbound_config)
  end

  defp put_outbound_config(changeset) do
    wg_config = get_field(changeset, :wg_config)

    outbound_config = %{
      "wg_config" => wg_config
    }

    put_change(changeset, :outbound_config, outbound_config)
  end
end
