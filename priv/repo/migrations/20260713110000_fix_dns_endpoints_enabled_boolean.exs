defmodule Hermit.Repo.Migrations.FixDnsEndpointsEnabledBoolean do
  use Ecto.Migration

  def up do
    execute "UPDATE dns_endpoints SET enabled = 1 WHERE enabled = 'true'"
    execute "UPDATE dns_endpoints SET enabled = 0 WHERE enabled = 'false'"
  end

  def down do
    # No-op: 1 and 0 are the correct representation of boolean in SQLite for Ecto.
    :ok
  end
end
