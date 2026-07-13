defmodule Hermit.Repo.Migrations.AddEnableEcsToDnsConfigs do
  use Ecto.Migration

  def change do
    alter table(:dns_configs) do
      add(:enable_ecs, :boolean, default: false, null: false)
    end
  end
end
