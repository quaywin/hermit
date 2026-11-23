defmodule Hermit.Repo.Migrations.ReplaceLocalBlocklistsWithUpstreamFiltering do
  use Ecto.Migration

  def up do
    drop_if_exists table(:dns_configs_blocklists)
    drop_if_exists table(:dns_blocklist_hourly_stats)
    drop_if_exists table(:dns_blocklists)

    alter table(:dns_hourly_stats) do
      add :upstream_blocked_count, :integer, default: 0, null: false
    end
  end

  def down do
    alter table(:dns_hourly_stats) do
      remove :upstream_blocked_count
    end
  end
end
