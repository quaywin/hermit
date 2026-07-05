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
    attrs = stringify_config_keys(attrs)

    outbound_profile
    |> cast(attrs, [:name, :type, :config])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, ["wireguard", "local"])
    |> validate_config()
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
      "wireguard" ->
        wg_config = Map.get(config, "wg_config") || Map.get(config, :wg_config)

        if is_nil(wg_config) || wg_config == "" do
          add_error(changeset, :config, "WireGuard requires wg_config payload")
        else
          changeset
        end

      "local" ->
        local_ip = Map.get(config, "local_ip") || Map.get(config, :local_ip)
        host_ip = Map.get(config, "host_ip") || Map.get(config, :host_ip)

        changeset
        |> validate_ip_cidr(local_ip, :local_ip)
        |> validate_ip_cidr(host_ip, :host_ip)

      _ ->
        changeset
    end
  end

  defp validate_ip_cidr(changeset, nil, _field), do: changeset
  defp validate_ip_cidr(changeset, "", _field), do: changeset

  defp validate_ip_cidr(changeset, value, field) do
    case Regex.match?(~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\/\d{1,2}$/, value) do
      true ->
        changeset

      false ->
        add_error(changeset, :config, "#{field} must be in CIDR format (e.g. 10.200.1.2/30)")
    end
  end
end
