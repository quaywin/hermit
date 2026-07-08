defmodule Hermit.Repo.Migrations.AddBlockIpv6ToDnsConfigs do
  use Ecto.Migration

  def change do
    alter table(:dns_configs) do
      add :block_ipv6, :boolean, default: false, null: false
    end
  end
end
