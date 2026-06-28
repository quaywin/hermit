defmodule Hermit.Repo.Migrations.CreateVpnPairs do
  use Ecto.Migration

  def change do
    create table(:vpn_pairs, primary_key: false) do
      add :pair_id, :string, primary_key: true
      add :ts_auth_key, :string
      add :wg_config, :text, null: false
      add :status, :string, default: "running", null: false

      timestamps()
    end
  end
end
