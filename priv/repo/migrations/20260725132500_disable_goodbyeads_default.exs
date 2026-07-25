defmodule Hermit.Repo.Migrations.DisableGoodbyeadsDefault do
  use Ecto.Migration

  def up do
    execute "UPDATE dns_blocklists SET enabled = 0 WHERE name LIKE '%GoodbyeAds%';"
  end

  def down do
    execute "UPDATE dns_blocklists SET enabled = 1 WHERE name LIKE '%GoodbyeAds%';"
  end
end
