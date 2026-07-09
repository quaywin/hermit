defmodule Hermit.Repo.Migrations.CreateDnsBlocklists do
  use Ecto.Migration

  def up do
    create table(:dns_blocklists) do
      add :name, :string, null: false
      add :url, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :description, :string
      add :format, :string, default: "adguard", null: false
      add :rules_count, :integer, default: 0, null: false
      add :last_fetched_at, :naive_datetime

      timestamps()
    end

    create table(:dns_configs_blocklists, primary_key: false) do
      add :dns_config_id, references(:dns_configs, on_delete: :delete_all), primary_key: true
      add :dns_blocklist_id, references(:dns_blocklists, on_delete: :delete_all), primary_key: true
    end

    create index(:dns_configs_blocklists, [:dns_config_id])
    create index(:dns_configs_blocklists, [:dns_blocklist_id])
    create unique_index(:dns_configs_blocklists, [:dns_config_id, :dns_blocklist_id])

    # Insert default blocklists
    execute """
    INSERT INTO dns_blocklists (name, url, enabled, description, format, rules_count, inserted_at, updated_at)
    VALUES ('AdGuard DNS Filter', 'https://raw.githubusercontent.com/AdguardTeam/HostlistsRegistry/refs/heads/main/filters/general/filter_1_DnsFilter/filter.txt', 1, 'Blocks known ads, analytics, trackers, and telemetry domains.', 'adguard', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    """

    execute """
    INSERT INTO dns_blocklists (name, url, enabled, description, format, rules_count, inserted_at, updated_at)
    VALUES ('GoodbyeAds Filter', 'https://raw.githubusercontent.com/jerryn70/GoodbyeAds/master/Hosts/GoodbyeAds.txt', 1, 'Blocks aggressive mobile trackers, ads, and telemetry.', 'hosts', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    """

    # Migrate existing configurations:
    execute """
    INSERT INTO dns_configs_blocklists (dns_config_id, dns_blocklist_id)
    SELECT id, 1 FROM dns_configs WHERE block_ads = 1
    """

    execute """
    INSERT INTO dns_configs_blocklists (dns_config_id, dns_blocklist_id)
    SELECT id, 2 FROM dns_configs WHERE block_goodbyeads = 1
    """
  end

  def down do
    drop table(:dns_configs_blocklists)
    drop table(:dns_blocklists)
  end
end
