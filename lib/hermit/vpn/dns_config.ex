defmodule Hermit.Vpn.DnsConfig do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_configs" do
    field :enabled, :boolean, default: false
    field :block_ads, :boolean, default: false
    field :block_adult, :boolean, default: false
    field :upstream_dns, :string, default: "1.1.1.1, 8.8.8.8"
    field :custom_rules, {:array, :map}, default: []
    field :tailscale_override_dns, :boolean, default: false

    timestamps()
  end

  def changeset(dns_config, attrs) do
    dns_config
    |> cast(attrs, [:enabled, :block_ads, :block_adult, :upstream_dns, :custom_rules, :tailscale_override_dns])
    |> validate_required([:upstream_dns, :custom_rules])
    |> validate_upstream_dns()
    |> validate_custom_rules()
  end

  defp validate_upstream_dns(changeset) do
    case get_field(changeset, :upstream_dns) do
      nil ->
        changeset

      upstream ->
        ips = String.split(upstream, [",", " "], trim: true)
        if Enum.all?(ips, &valid_ip?/1) do
          changeset
        else
          add_error(changeset, :upstream_dns, "contains invalid IP address(es)")
        end
    end
  end

  defp valid_ip?(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _} -> true
      _ -> false
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

  # Seed helper
  def get_global do
    try do
      case Hermit.Repo.one(__MODULE__) do
        nil ->
          %__MODULE__{}
          |> changeset(%{custom_rules: []})
          |> Hermit.Repo.insert!()

        config ->
          config
      end
    rescue
      _ ->
        %__MODULE__{enabled: false, custom_rules: []}
    end
  end

  def update_global(attrs) do
    get_global()
    |> changeset(attrs)
    |> Hermit.Repo.update()
  end
end
