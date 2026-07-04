defmodule Hermit.Repo.Migrations.AddBlockGoodbyeadsToDnsConfigs do
  use Ecto.Migration

  def change do
    alter table(:dns_configs) do
      add :block_goodbyeads, :boolean, default: false, null: false
    end
  end
end
