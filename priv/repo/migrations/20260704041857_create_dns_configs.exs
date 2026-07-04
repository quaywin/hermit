defmodule Hermit.Repo.Migrations.CreateDnsConfigs do
  use Ecto.Migration

  def change do
    create table(:dns_configs) do
      add :enabled, :boolean, default: false, null: false
      add :block_ads, :boolean, default: false, null: false
      add :block_adult, :boolean, default: false, null: false
      add :upstream_dns, :string, default: "1.1.1.1, 8.8.8.8", null: false
      add :custom_rules, :map, null: false
      add :tailscale_override_dns, :boolean, default: false, null: false

      timestamps()
    end
  end
end
