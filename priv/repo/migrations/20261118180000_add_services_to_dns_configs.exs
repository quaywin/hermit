defmodule Hermit.Repo.Migrations.AddServicesToDnsConfigs do
  use Ecto.Migration

  def change do
    alter table(:dns_configs) do
      add :services, :map, default: "{}", null: false
    end
  end
end
