defmodule Hermit.Repo.Migrations.AddDdnsHostnameToDnsEndpoints do
  use Ecto.Migration

  def up do
    execute fn ->
      columns = repo().query!("PRAGMA table_info(dns_endpoints)", []).rows
      has_col? = Enum.any?(columns, fn [_cid, name | _] -> name == "ddns_hostname" end)

      unless has_col? do
        repo().query!("ALTER TABLE dns_endpoints ADD COLUMN ddns_hostname TEXT", [])
      end
    end
  end

  def down do
    :ok
  end
end
