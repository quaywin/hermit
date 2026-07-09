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

    # Virtual field to maintain backward compatibility with old tests and code
    field(:inbound_profile_id, :integer, virtual: true)

    has_many(:inbound_profiles, Hermit.Vpn.InboundProfile, foreign_key: :dns_profile_id)

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
      :inbound_profile_id
    ])
    |> validate_required([:name, :upstream_dns, :custom_rules])
    |> validate_upstream_dns()
    |> validate_custom_rules()
    |> validate_inbound_profile_presence()
  end

  defp validate_inbound_profile_presence(changeset) do
    enabled = get_field(changeset, :enabled)
    inbound_profile_id = get_field(changeset, :inbound_profile_id)

    # Chỉ xác thực nếu trường ảo inbound_profile_id thực sự được truyền vào trong params để thay đổi
    # hoặc khi changeset explicitly muốn kiểm tra liên kết inbound
    is_profile_validation? =
      Map.has_key?(changeset.params || %{}, "inbound_profile_id") or
      Map.has_key?(changeset.params || %{}, :inbound_profile_id)

    if is_profile_validation? and enabled and is_nil(inbound_profile_id) do
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
    case Regex.run(~r/^\[(.*)\]:(\d+)$/, val) do
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
    action in ["block", "bypass", "redirect"] and is_binary(domain) and domain != ""
  end

  defp valid_rule?(_), do: false

  # Profile-specific helpers
  def get_for_profile(profile_id) do
    profile = Hermit.Repo.get(Hermit.Vpn.InboundProfile, profile_id)

    cond do
      is_nil(profile) ->
        # Trả về config trống nếu profile không tồn tại
        %__MODULE__{}

      is_nil(profile.dns_profile_id) ->
        # Nếu chưa liên kết DNS Profile nào, tự động tạo một DNS Profile riêng biệt cho Inbound này
        profile_dns_name = "DNS Profile for Inbound #{profile_id}"
        new_config =
          case Hermit.Repo.get_by(__MODULE__, name: profile_dns_name) do
            nil ->
              %__MODULE__{}
              |> changeset(%{name: profile_dns_name, custom_rules: []})
              |> Hermit.Repo.insert!()

            config ->
              config
          end

        # Gán dns_profile_id cho inbound profile
        profile
        |> Hermit.Vpn.InboundProfile.changeset(%{dns_profile_id: new_config.id})
        |> Hermit.Repo.update!()

        %{new_config | inbound_profile_id: profile_id}

      true ->
        config = Hermit.Repo.get!(__MODULE__, profile.dns_profile_id)
        %{config | inbound_profile_id: profile_id}
    end
  end

  def update_for_profile(profile_id, attrs) do
    config = get_for_profile(profile_id)
    attrs = Map.put(attrs, :inbound_profile_id, profile_id)

    # Đảm bảo trường :name không bị lỗi validate_required nếu attrs không truyền :name
    attrs = Map.put_new(attrs, :name, config.name)

    case config |> changeset(attrs) |> Hermit.Repo.update() do
      {:ok, updated} ->
        updated = %{updated | inbound_profile_id: profile_id}
        if :erlang.whereis(Hermit.PubSub) != :undefined do
          Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_config:#{profile_id}", {:dns_config_updated, updated})
        end
        {:ok, updated}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
