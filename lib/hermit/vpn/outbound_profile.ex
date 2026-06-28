defmodule Hermit.Vpn.OutboundProfile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "outbound_profiles" do
    field(:name, :string)
    field(:type, :string)
    field(:config, :map, default: %{})

    timestamps()
  end

  @doc false
  def changeset(outbound_profile, attrs) do
    outbound_profile
    |> cast(attrs, [:name, :type, :config])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, ["wireguard", "openvpn"])
    |> validate_config()
  end

  defp validate_config(changeset) do
    type = get_field(changeset, :type)
    config = get_field(changeset, :config) || %{}

    case type do
      "wireguard" ->
        wg_config = Map.get(config, "wg_config") || Map.get(config, :wg_config)

        if is_nil(wg_config) || wg_config == "" do
          add_error(changeset, :config, "WireGuard requires wg_config payload")
        else
          changeset
        end

      "openvpn" ->
        ovpn_config = Map.get(config, "ovpn_config") || Map.get(config, :ovpn_config)

        if is_nil(ovpn_config) || ovpn_config == "" do
          add_error(changeset, :config, "OpenVPN requires ovpn_config payload")
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
