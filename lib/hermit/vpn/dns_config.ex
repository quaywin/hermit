defmodule Hermit.Vpn.DnsConfig do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_configs" do
    field(:name, :string, default: "Default DNS Profile")
    field(:enabled, :boolean, default: false)
    field(:block_ads, :boolean, default: false)
    field(:block_goodbyeads, :boolean, default: false)
    field(:block_adult, :boolean, default: false)
    field(:block_ipv6, :boolean, default: false)
    field(:upstream_dns, :string, default: "1.1.1.1, 8.8.8.8")
    field(:custom_rules, {:array, :map}, default: [])
    field(:tailscale_override_dns, :boolean, default: false)
    field(:enable_query_logging, :boolean, default: false)
    field(:enable_ecs, :boolean, default: false)
    field(:ecs_fallback_ip, :string)

    # Virtual field to maintain backward compatibility with old tests and code
    field(:dns_endpoint_id, :integer, virtual: true)

    has_many(:dns_endpoints, Hermit.Vpn.DnsEndpoint, foreign_key: :dns_profile_id)

    many_to_many(:blocklists, Hermit.Dns.Blocklist,
      join_through: "dns_configs_blocklists",
      join_keys: [dns_config_id: :id, dns_blocklist_id: :id],
      on_replace: :delete
    )

    timestamps()
  end

  def changeset(dns_config, attrs) do
    dns_config
    |> cast(attrs, [
      :name,
      :enabled,
      :block_ads,
      :block_goodbyeads,
      :block_adult,
      :block_ipv6,
      :upstream_dns,
      :custom_rules,
      :tailscale_override_dns,
      :enable_query_logging,
      :enable_ecs,
      :ecs_fallback_ip,
      :dns_endpoint_id
    ])
    |> validate_required([:name, :upstream_dns, :custom_rules])
    |> validate_upstream_dns()
    |> validate_custom_rules()
    |> validate_ecs_fallback_ip()
  end

  defp validate_ecs_fallback_ip(changeset) do
    case get_field(changeset, :ecs_fallback_ip) do
      nil ->
        changeset

      "" ->
        changeset

      ip_str ->
        case :inet.parse_address(String.to_charlist(ip_str)) do
          {:ok, _} -> changeset
          _ -> add_error(changeset, :ecs_fallback_ip, "must be a valid IP address")
        end
    end
  end

  defp validate_upstream_dns(changeset) do
    case get_field(changeset, :upstream_dns) do
      nil ->
        changeset

      upstream ->
        targets = String.split(upstream, [",", " "], trim: true)

        if Enum.all?(targets, &valid_ip_or_url?/1) do
          changeset
        else
          add_error(changeset, :upstream_dns, "contains invalid IP address(es) or URL(s)")
        end
    end
  end

  defp valid_ip_or_url?(val) do
    cond do
      String.starts_with?(val, "https://") ->
        true

      true ->
        case parse_ip_and_port(val) do
          {:ok, _ip, _port} -> true
          {:ok, _ip} -> true
          :error -> false
        end
    end
  end

  defp parse_ip_and_port(val) do
    case Regex.run(~r/^\\[(.*)\\]:(\\d+)$/, val) do
      [_, ip_str, port_str] ->
        with {:ok, ip} <- :inet.parse_address(String.to_charlist(ip_str)),
             {port, ""} <- Integer.parse(port_str) do
          {:ok, ip, port}
        else
          _ -> :error
        end

      nil ->
        case String.split(val, ":") do
          [ip_str, port_str] ->
            with {:ok, ip} <- :inet.parse_address(String.to_charlist(ip_str)),
                 {port, ""} <- Integer.parse(port_str) do
              {:ok, ip, port}
            else
              _ -> :error
            end

          _ ->
            case :inet.parse_address(String.to_charlist(val)) do
              {:ok, ip} -> {:ok, ip}
              _ -> :error
            end
        end
    end
  end

  defp validate_custom_rules(changeset) do
    case get_field(changeset, :custom_rules) do
      rules when is_list(rules) ->
        if Enum.all?(rules, &valid_rule?/1) do
          changeset
        else
          add_error(changeset, :custom_rules, "contains invalid custom rules")
        end

      nil ->
        changeset

      _ ->
        add_error(changeset, :custom_rules, "must be a list")
    end
  end

  defp valid_rule?(rule) when is_map(rule) do
    domain = Map.get(rule, "domain") || Map.get(rule, :domain)
    action = Map.get(rule, "action") || Map.get(rule, :action)
    proxy_pair_id = Map.get(rule, "proxy_pair_id") || Map.get(rule, :proxy_pair_id)

    action_valid? = action in ["block", "bypass", "redirect", "forward_proxy", "forward_dns"]
    domain_valid? = is_binary(domain) and domain != ""
    proxy_valid? = is_nil(proxy_pair_id) or is_binary(proxy_pair_id)

    action_valid? and domain_valid? and proxy_valid?
  end

  defp valid_rule?(_), do: false

  # Endpoint-specific helpers
  def get_for_endpoint(endpoint_id) do
    endpoint = Hermit.Repo.get(Hermit.Vpn.DnsEndpoint, endpoint_id)

    cond do
      is_nil(endpoint) ->
        %__MODULE__{blocklists: []}

      is_nil(endpoint.dns_profile_id) ->
        endpoint_dns_name = "DNS Profile for Endpoint #{endpoint_id}"

        new_config =
          case Hermit.Repo.get_by(__MODULE__, name: endpoint_dns_name) do
            nil ->
              %__MODULE__{}
              |> changeset(%{name: endpoint_dns_name, custom_rules: []})
              |> Hermit.Repo.insert!()

            config ->
              config
          end

        endpoint
        |> Hermit.Vpn.DnsEndpoint.changeset(%{dns_profile_id: new_config.id})
        |> Hermit.Repo.update!()

        Hermit.Vpn.DnsEndpoint.clear_cache()

        new_config = Hermit.Repo.preload(new_config, :blocklists)
        %{new_config | dns_endpoint_id: endpoint_id}

      true ->
        config =
          Hermit.Repo.get!(__MODULE__, endpoint.dns_profile_id)
          |> Hermit.Repo.preload(:blocklists)

        %{config | dns_endpoint_id: endpoint_id}
    end
  end

  def update_for_endpoint(endpoint_id, attrs) do
    config = get_for_endpoint(endpoint_id)
    attrs = Map.put(attrs, :dns_endpoint_id, endpoint_id)
    attrs = Map.put_new(attrs, :name, config.name)

    case config |> changeset(attrs) |> Hermit.Repo.update() do
      {:ok, updated} ->
        updated = updated |> Hermit.Repo.preload(:blocklists)
        updated = %{updated | dns_endpoint_id: endpoint_id}

        if :erlang.whereis(Hermit.PubSub) != :undefined do
          Phoenix.PubSub.broadcast(
            Hermit.PubSub,
            "dns_config:#{endpoint_id}",
            {:dns_config_updated, updated}
          )
        end

        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_blocklists(config, blocklist_ids) do
    import Ecto.Query
    blocklists = Hermit.Repo.all(from(b in Hermit.Dns.Blocklist, where: b.id in ^blocklist_ids))

    config
    |> Hermit.Repo.preload(:blocklists)
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:blocklists, blocklists)
    |> Hermit.Repo.update()
  end
end
