defmodule Hermit.Vpn.DnsEndpoint do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_endpoints" do
    field(:name, :string)
    field(:doh_token, :string)
    field(:enabled, :boolean, default: false)

    belongs_to(:dns_profile, Hermit.Vpn.DnsConfig, foreign_key: :dns_profile_id)
    belongs_to(:inbound_profile, Hermit.Vpn.InboundProfile, foreign_key: :inbound_profile_id)

    timestamps()
  end

  @doc false
  def changeset(dns_endpoint, attrs) do
    dns_endpoint
    |> cast(attrs, [:name, :doh_token, :enabled, :dns_profile_id, :inbound_profile_id])
    |> put_doh_token()
    |> validate_required([:name, :doh_token, :dns_profile_id])
    |> unique_constraint(:doh_token)
  end

  defp put_doh_token(changeset) do
    case get_field(changeset, :doh_token) do
      nil ->
        token = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
        put_change(changeset, :doh_token, token)

      _ ->
        changeset
    end
  end

  # Cache helpers
  def get_by_doh_token(doh_token) do
    try do
      case :ets.lookup(:inbound_profiles_cache, {:dns_endpoint, doh_token}) do
        [{_, endpoint}] ->
          endpoint

        [] ->
          case Hermit.Repo.get_by(__MODULE__, doh_token: doh_token)
               |> Hermit.Repo.preload(:dns_profile) do
            nil ->
              nil

            endpoint ->
              :ets.insert(:inbound_profiles_cache, {{:dns_endpoint, doh_token}, endpoint})
              endpoint
          end
      end
    rescue
      ArgumentError ->
        Hermit.Repo.get_by(__MODULE__, doh_token: doh_token) |> Hermit.Repo.preload(:dns_profile)
    end
  end

  def clear_cache do
    try do
      :ets.delete_all_objects(:inbound_profiles_cache)
    rescue
      ArgumentError -> :ok
    end
  end
end
