defmodule Hermit.Repo.Migrations.AddUniqueIndexToDnsConfigs do
  use Ecto.Migration

  def change do
    create unique_index(:dns_configs, [:inbound_profile_id])
  end
end
