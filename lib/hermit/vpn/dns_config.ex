defmodule Hermit.Vpn.DnsConfig do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_configs" do
    field(:enabled, :boolean, default: false)
    field(:block_ads, :boolean, default: false)
    field(:block_goodbyeads, :boolean, default: false)
    field(:block_adult, :boolean, default: false)
    field(:upstream_dns, :string, default: "1.1.1.1, 8.8.8.8")
    field(:custom_rules, {:array, :map}, default: [])
    field(:tailscale_override_dns, :boolean, default: false)
    field(:enable_query_logging, :boolean, default: false)

    belongs_to(:inbound_profile, Hermit.Vpn.InboundProfile)

    timestamps()
  end

  def changeset(dns_config, attrs) do
    dns_config
    |> cast(attrs, [
      :enabled,
      :block_ads,
      :block_goodbyeads,
      :block_adult,
      :upstream_dns,
      :custom_rules,
      :tailscale_override_dns,
      :enable_query_logging,
      :inbound_profile_id
    ])
    |> validate_required([:upstream_dns, :custom_rules])
    |> validate_upstream_dns()
    |> validate_custom_rules()
    |> validate_inbound_profile_presence()
  end

  defp validate_inbound_profile_presence(changeset) do
    enabled = get_field(changeset, :enabled)
    inbound_profile_id = get_field(changeset, :inbound_profile_id)

    if enabled && is_nil(inbound_profile_id) do
      add_error(
        changeset,
        :inbound_profile_id,
        "must be selected when Global DNS Filtering is enabled"
      )
    else
      changeset
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
    case :inet.parse_address(String.to_charlist(val)) do
      {:ok, _} -> true
      _ -> String.starts_with?(val, "https://")
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
    action in ["block", "bypass", "redirect"] and is_binary(domain) and domain != ""
  end

  defp valid_rule?(_), do: false

  # Profile-specific helpers
  def get_for_profile(profile_id) do
    case Hermit.Repo.get_by(__MODULE__, inbound_profile_id: profile_id) do
      nil ->
        %__MODULE__{inbound_profile_id: profile_id}
        |> changeset(%{custom_rules: []})
        |> Hermit.Repo.insert!()
        |> Hermit.Repo.preload(:inbound_profile)

      config ->
        config
        |> Hermit.Repo.preload(:inbound_profile)
    end
  end

  def update_for_profile(profile_id, attrs) do
    case get_for_profile(profile_id) |> changeset(attrs) |> Hermit.Repo.update() do
      {:ok, updated} ->
        updated = Hermit.Repo.preload(updated, :inbound_profile)
        if :erlang.whereis(Hermit.PubSub) != :undefined do
          Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_config:#{profile_id}", {:dns_config_updated, updated})
        end
        {:ok, updated}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
