defmodule Hermit.Repo.Migrations.CreateVpnProfiles do
  use Ecto.Migration

  def up do
    create table(:inbound_profiles) do
      add :name, :string, null: false
      add :type, :string, null: false
      add :config, :map, null: false, default: "{}"

      timestamps()
    end

    create table(:outbound_profiles) do
      add :name, :string, null: false
      add :type, :string, null: false
      add :config, :map, null: false, default: "{}"

      timestamps()
    end

    # Drop existing vpn_pairs table
    drop table(:vpn_pairs)

    # Recreate vpn_pairs table with the new schema (no old fields, only profile references)
    create table(:vpn_pairs, primary_key: false) do
      add :pair_id, :string, primary_key: true
      add :inbound_profile_id, references(:inbound_profiles, on_delete: :nilify_all)
      add :outbound_profile_id, references(:outbound_profiles, on_delete: :nilify_all)
      add :status, :string, default: "running", null: false
      add :wg_status, :string, default: "stopped", null: false
      add :ts_status, :string, default: "stopped", null: false
      add :wg_error_reason, :text
      add :ts_error_reason, :text
      add :started_at, :integer

      timestamps()
    end
  end

  def down do
    drop table(:vpn_pairs)

    # Recreate the old table in case of rollback
    create table(:vpn_pairs, primary_key: false) do
      add :pair_id, :string, primary_key: true
      add :ts_auth_key, :string
      add :wg_config, :text, null: false
      add :status, :string, default: "running", null: false
      add :wg_status, :string, default: "stopped", null: false
      add :ts_status, :string, default: "stopped", null: false
      add :wg_error_reason, :text
      add :ts_error_reason, :text
      add :started_at, :integer
      add :inbound_type, :string, default: "tailscale", null: false
      add :inbound_config, :map
      add :outbound_type, :string, default: "wireguard", null: false
      add :outbound_config, :map

      timestamps()
    end

    drop table(:outbound_profiles)
    drop table(:inbound_profiles)
  end
end
