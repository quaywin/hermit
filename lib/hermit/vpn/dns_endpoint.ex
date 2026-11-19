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
    |> cast(attrs, [
      :name,
      :doh_token,
      :enabled,
      :dns_profile_id,
      :inbound_profile_id
    ])
    |> put_internal_token()
    |> validate_required([:name, :dns_profile_id])
    |> validate_enabled_has_inbound()
    |> unique_constraint(:doh_token)
  end

  defp validate_enabled_has_inbound(changeset) do
    enabled = get_field(changeset, :enabled)
    inbound_id = get_field(changeset, :inbound_profile_id)

    if enabled and is_nil(inbound_id) do
      add_error(changeset, :inbound_profile_id, "is required to activate DNS Endpoint")
    else
      changeset
    end
  end

  # Keeps backward compatibility with the NOT NULL unique doh_token column in existing SQLite DBs
  defp put_internal_token(changeset) do
    case get_field(changeset, :doh_token) do
      nil ->
        token = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
        put_change(changeset, :doh_token, token)

      _ ->
        changeset
    end
  end

  def clear_cache do
    try do
      :ets.match_delete(:inbound_profiles_cache, {{:dns_endpoint, :_}, :_})
      :ets.match_delete(:inbound_profiles_cache, {{:doh_token, :_}, :_, :_})
      Hermit.Vpn.SniProxy.IpResolver.clear_cache()
    rescue
      ArgumentError -> :ok
    end
  end
end
