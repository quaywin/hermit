defmodule Hermit.Vpn.VpnPair do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:pair_id, :string, autogenerate: false}
  schema "vpn_pairs" do
    field(:ts_auth_key, :string)
    field(:wg_config, :string)
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
  end
end
