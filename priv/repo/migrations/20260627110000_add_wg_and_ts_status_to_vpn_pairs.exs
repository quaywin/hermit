defmodule Hermit.Repo.Migrations.AddWgAndTsStatusToVpnPairs do
  use Ecto.Migration

  def change do
    alter table(:vpn_pairs) do
      add :wg_status, :string, default: "stopped", null: false
      add :ts_status, :string, default: "stopped", null: false
      add :wg_error_reason, :text
      add :ts_error_reason, :text
    end
  end
end
