defmodule Hermit.Repo.Migrations.AddEnableQueryLoggingToDnsConfigs do
  use Ecto.Migration

  def change do
    alter table(:dns_configs) do
      add :enable_query_logging, :boolean, default: false, null: false
    end
  end
end
