defmodule Hermit.Repo.Migrations.AddTailscaleDnsModeToDnsConfigs do
  use Ecto.Migration

  def change do
    alter table(:dns_configs) do
      add(:tailscale_dns_mode, :string, default: "split", null: false)
    end
  end
end
