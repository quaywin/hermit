defmodule Hermit.Vpn.InboundProfile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "inbound_profiles" do
    field(:name, :string)
    field(:type, :string)
    field(:config, :map, default: %{})
    field(:doh_token, :string)

    belongs_to(:dns_profile, Hermit.Vpn.DnsConfig, foreign_key: :dns_profile_id)

    timestamps()
  end

  @doc false
  def changeset(inbound_profile, attrs) do
    attrs = stringify_config_keys(attrs)

    inbound_profile
    |> cast(attrs, [:name, :type, :config, :dns_profile_id, :doh_token])
    |> put_doh_token()
    |> validate_required([:name, :type, :doh_token])
    |> validate_inclusion(:type, ["tailscale", "proxy"])
    |> validate_config()
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

  defp stringify_config_keys(attrs) do
    case attrs do
      %{"config" => config} when is_map(config) ->
        Map.put(attrs, "config", stringify_keys(config))

      %{config: config} when is_map(config) ->
        Map.put(attrs, :config, stringify_keys(config))

      _ ->
        attrs
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(val), do: val

  defp validate_config(changeset) do
    type = get_field(changeset, :type)
    config = get_field(changeset, :config) || %{}

    case type do
      "tailscale" ->
        # ts_auth_key is optional since it falls back to global settings, but config should be a map
        if is_map(config) do
          changeset
        else
          add_error(changeset, :config, "must be a map")
        end

      "proxy" ->
        if is_map(config) do
          port = Map.get(config, "port") || Map.get(config, :port)

          cond do
            is_nil(port) || port == "" || port == 0 || port == "0" ->
              changeset

            is_integer(port) and port > 0 and port <= 65535 ->
              changeset

            is_binary(port) ->
              case Integer.parse(port) do
                {val, ""} when val > 0 and val <= 65535 ->
                  changeset

                _ ->
                  add_error(
                    changeset,
                    :config,
                    "Proxy port must be a valid number between 1 and 65535"
                  )
              end

            true ->
              add_error(
                changeset,
                :config,
                "Proxy port must be a valid number between 1 and 65535"
              )
          end
        else
          add_error(changeset, :config, "must be a map")
        end

      _ ->
        changeset
    end
  end
end
