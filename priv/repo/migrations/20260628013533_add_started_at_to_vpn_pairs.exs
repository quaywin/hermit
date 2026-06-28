defmodule Hermit.Repo.Migrations.AddStartedAtToVpnPairs do
  use Ecto.Migration

  def change do
    alter table(:vpn_pairs) do
      add :started_at, :integer
    end
  end
end
