defmodule Hermit.Vpn.Form do
  use Ecto.Schema
  import Ecto.Changeset

  # Schema-less embedded schema for form validations
  @primary_key false
  embedded_schema do
    field(:pair_id, :string)
    field(:inbound_profile_id, :integer)
    field(:outbound_profile_id, :integer)
  end

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:pair_id, :inbound_profile_id, :outbound_profile_id])
    |> validate_required([:pair_id, :inbound_profile_id, :outbound_profile_id])
    |> validate_format(:pair_id, ~r/^[a-z0-9_]+$/,
      message: "must contain only lowercase letters, numbers, and underscores"
    )
  end
end
