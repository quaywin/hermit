defmodule Hermit.Vpn.Form do
  use Ecto.Schema
  import Ecto.Changeset

  # Schema-less embedded schema for form validations
  @primary_key false
  embedded_schema do
    field(:pair_id, :string)
    field(:ts_auth_key, :string)
    field(:wg_config, :string)
  end

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:pair_id, :wg_config])
    |> validate_required([:pair_id, :wg_config])
    |> validate_format(:pair_id, ~r/^[a-z0-9_]+$/,
      message: "must contain only lowercase letters, numbers, and underscores"
    )
    |> validate_global_auth_key()
  end

  defp validate_global_auth_key(changeset) do
    default_key =
      Hermit.Vpn.Setting.get_value("tailscale_auth_key") ||
        Application.get_env(:hermit, :docker)[:tailscale_auth_key]

    if is_nil(default_key) || default_key == "" do
      add_error(
        changeset,
        :pair_id,
        "Please configure a Default Tailscale Auth Key in Global Settings first."
      )
    else
      changeset
    end
  end
end
