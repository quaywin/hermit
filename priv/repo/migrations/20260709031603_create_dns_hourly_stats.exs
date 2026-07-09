defmodule Hermit.Repo.Migrations.CreateDnsHourlyStats do
  use Ecto.Migration

  def change do
    create table(:dns_hourly_stats) do
      add :dns_config_id, references(:dns_configs, on_delete: :delete_all), null: false
      add :hour_timestamp, :integer, null: false
      add :total_queries, :integer, default: 0, null: false
      add :blocked_queries, :integer, default: 0, null: false
      add :ipv6_blocked_count, :integer, default: 0, null: false

      timestamps()
    end

    create unique_index(:dns_hourly_stats, [:dns_config_id, :hour_timestamp])
  end
end
