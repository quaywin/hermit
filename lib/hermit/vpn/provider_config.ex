defmodule Hermit.Vpn.ProviderConfig do
  use Ecto.Schema
  import Ecto.Changeset

  schema "provider_configs" do
    field(:name, :string)
    field(:provider, :string)
    field(:config, :map, default: %{})

    timestamps()
  end

  @doc false
  def changeset(provider_config, attrs) do
    provider_config
    |> cast(attrs, [:name, :provider, :config])
    |> validate_required([:name, :provider])
    |> validate_inclusion(:provider, ["nordvpn", "mullvad", "custom"])
    |> validate_config()
  end

  defp validate_config(changeset) do
    config = get_field(changeset, :config) || %{}
    wg_config = Map.get(config, "wg_config") || Map.get(config, :wg_config)

    if is_nil(wg_config) || wg_config == "" do
      add_error(changeset, :config, "WireGuard configuration is required")
    else
      changeset
    end
  end
end
