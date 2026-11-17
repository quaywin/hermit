defmodule Hermit.Repo.Migrations.DropProviderConfigs do
  use Ecto.Migration

  def change do
    drop_if_exists table(:provider_configs)
  end
end
