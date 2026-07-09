defmodule Hermit.Repo.Migrations.AddAdultBlocklist do
  use Ecto.Migration

  def up do
    execute """
    INSERT INTO dns_blocklists (name, url, enabled, description, format, rules_count, inserted_at, updated_at)
    VALUES ('Adult Content Filter', 'priv/dns_blocklists/adult_domains.txt', 1, 'Blocks major adult websites and pornography domains.', 'domains', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    """

    execute """
    INSERT INTO dns_configs_blocklists (dns_config_id, dns_blocklist_id)
    SELECT id, 3 FROM dns_configs WHERE block_adult = 1
    """
  end

  def down do
    execute "DELETE FROM dns_configs_blocklists WHERE dns_blocklist_id = 3"
    execute "DELETE FROM dns_blocklists WHERE id = 3"
  end
end
