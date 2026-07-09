defmodule Hermit.Repo.Migrations.CreateDnsBlocklistHourlyStats do
  use Ecto.Migration

  def change do
    create table(:dns_blocklist_hourly_stats) do
      add :dns_config_id, references(:dns_configs, on_delete: :delete_all), null: false
      add :dns_blocklist_id, references(:dns_blocklists, on_delete: :delete_all), null: false
      add :hour_timestamp, :integer, null: false
      add :blocked_count, :integer, default: 0, null: false

      timestamps()
    end

    create index(:dns_blocklist_hourly_stats, [:dns_config_id])
    create index(:dns_blocklist_hourly_stats, [:dns_blocklist_id])
    create unique_index(:dns_blocklist_hourly_stats, [:dns_config_id, :dns_blocklist_id, :hour_timestamp])
  end
end
