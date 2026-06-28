defmodule Hermit.Repo.Migrations.AddModularConfigsToVpnPairs do
  use Ecto.Migration

  def up do
    alter table(:vpn_pairs) do
      add :inbound_type, :string, default: "tailscale", null: false
      add :inbound_config, :map
      add :outbound_type, :string, default: "wireguard", null: false
      add :outbound_config, :map
    end

    flush()

    # Data migration: Convert old columns to JSON format using SQLite json_object
    execute """
    UPDATE vpn_pairs
    SET inbound_config = json_object('ts_auth_key', COALESCE(ts_auth_key, '')),
        outbound_config = json_object('wg_config', COALESCE(wg_config, ''))
    """
  end

  def down do
    alter table(:vpn_pairs) do
      remove :inbound_type
      remove :inbound_config
      remove :outbound_type
      remove :outbound_config
    end
  end
end
