defmodule Hermit.Repo.Migrations.AddConfigsToVpnPairs do
  use Ecto.Migration

  def change do
    alter table(:vpn_pairs) do
      add :inbound_type, :string, default: "tailscale", null: false
      add :inbound_config, :map
      add :outbound_type, :string, default: "wireguard", null: false
      add :outbound_config, :map
    end
  end
end
