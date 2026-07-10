defmodule Hermit.Repo.Migrations.CreateProviderConfigs do
  use Ecto.Migration

  def change do
    create table(:provider_configs) do
      add :name, :string, null: false
      add :provider, :string, null: false
      add :config, :map, null: false, default: "{}"

      timestamps()
    end

    # Index on provider for fast filtering
    create index(:provider_configs, [:provider])
  end
end
