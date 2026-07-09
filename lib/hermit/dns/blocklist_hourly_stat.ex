defmodule Hermit.Dns.BlocklistHourlyStat do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_blocklist_hourly_stats" do
    field :dns_config_id, :integer
    field :dns_blocklist_id, :integer
    field :hour_timestamp, :integer
    field :blocked_count, :integer, default: 0

    timestamps()
  end

  def changeset(stat, attrs) do
    stat
    |> cast(attrs, [:dns_config_id, :dns_blocklist_id, :hour_timestamp, :blocked_count])
    |> validate_required([:dns_config_id, :dns_blocklist_id, :hour_timestamp])
    |> unique_constraint([:dns_config_id, :dns_blocklist_id, :hour_timestamp])
  end
end
