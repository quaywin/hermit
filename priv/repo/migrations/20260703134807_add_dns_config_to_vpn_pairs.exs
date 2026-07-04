defmodule Hermit.Repo.Migrations.AddDnsConfigToVpnPairs do
  use Ecto.Migration

  def change do
    alter table(:vpn_pairs) do
      add :dns_config, :map
    end
  end
end
