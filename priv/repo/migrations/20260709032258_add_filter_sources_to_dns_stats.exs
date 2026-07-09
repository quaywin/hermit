defmodule Hermit.Repo.Migrations.AddFilterSourcesToDnsStats do
  use Ecto.Migration

  def change do
    alter table(:dns_hourly_stats) do
      add :adguard_blocked_count, :integer, default: 0, null: false
      add :goodbyeads_blocked_count, :integer, default: 0, null: false
      add :adult_blocked_count, :integer, default: 0, null: false
      add :custom_blocked_count, :integer, default: 0, null: false
    end
  end
end
