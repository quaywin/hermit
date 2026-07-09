defmodule Hermit.Dns.HourlyStat do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_hourly_stats" do
    field :dns_config_id, :integer
    field :hour_timestamp, :integer
    field :total_queries, :integer, default: 0
    field :blocked_queries, :integer, default: 0
    field :ipv6_blocked_count, :integer, default: 0
    field :adguard_blocked_count, :integer, default: 0
    field :goodbyeads_blocked_count, :integer, default: 0
    field :adult_blocked_count, :integer, default: 0
    field :custom_blocked_count, :integer, default: 0

    timestamps()
  end

  def changeset(hourly_stat, attrs) do
    hourly_stat
    |> cast(attrs, [
      :dns_config_id,
      :hour_timestamp,
      :total_queries,
      :blocked_queries,
      :ipv6_blocked_count,
      :adguard_blocked_count,
      :goodbyeads_blocked_count,
      :adult_blocked_count,
      :custom_blocked_count
    ])
    |> validate_required([:dns_config_id, :hour_timestamp])
    |> foreign_key_constraint(:dns_config_id)
    |> unique_constraint([:dns_config_id, :hour_timestamp])
  end
end
