defmodule Hermit.Vpn.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "settings" do
    field(:value, :string)

    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
    |> validate_auth_key()
  end

  def get_value(key, default \\ nil) do
    case Hermit.Repo.get(__MODULE__, key) do
      nil -> default
      setting -> setting.value
    end
  end

  def put_value(key, value) do
    setting = Hermit.Repo.get(__MODULE__, key) || %__MODULE__{key: key}

    setting
    |> changeset(%{value: value})
    |> Hermit.Repo.insert_or_update()
  end

  defp validate_auth_key(changeset) do
    key = get_field(changeset, :key)
    value = get_field(changeset, :value)

    cond do
      key == "tailscale_auth_key" and value != "" and value != nil and
          not String.starts_with?(value, "tskey-") ->
        add_error(changeset, :value, "must start with 'tskey-'")

      key == "tailscale_api_key" and value != "" and value != nil and
          not String.starts_with?(value, "tskey-api-") ->
        add_error(changeset, :value, "must start with 'tskey-api-'")

      true ->
        changeset
    end
  end
end
