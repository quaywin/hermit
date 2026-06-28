defmodule Hermit.Vpn.VpnPair do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:pair_id, :string, autogenerate: false}
  schema "vpn_pairs" do
    belongs_to(:inbound_profile, Hermit.Vpn.InboundProfile)
    belongs_to(:outbound_profile, Hermit.Vpn.OutboundProfile)

    field(:wg_config, :string, virtual: true)

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
      :inbound_profile_id,
      :outbound_profile_id,
      :wg_config,
      :status,
      :wg_status,
      :ts_status,
      :wg_error_reason,
      :ts_error_reason,
      :started_at
    ])
    |> validate_required([:pair_id, :inbound_profile_id, :outbound_profile_id])
    |> validate_format(:pair_id, ~r/^[a-z0-9_]+$/,
      message: "must contain only lowercase letters, numbers, and underscores"
    )
    |> validate_wg_config_if_present()
  end

  defp validate_wg_config_if_present(changeset) do
    if Map.has_key?(changeset.params || %{}, "wg_config") do
      val = get_field(changeset, :wg_config)

      if is_nil(val) or String.trim(val) == "" do
        add_error(changeset, :wg_config, "can't be blank")
      else
        changeset
      end
    else
      changeset
    end
  end
end
