defmodule Hermit.Repo.Migrations.AddEcsFallbackIpToDnsConfigs do
  use Ecto.Migration

  def change do
    alter table(:dns_configs) do
      add(:ecs_fallback_ip, :string)
    end
  end
end
