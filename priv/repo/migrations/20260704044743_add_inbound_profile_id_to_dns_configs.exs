defmodule Hermit.Repo.Migrations.AddInboundProfileIdToDnsConfigs do
  use Ecto.Migration

  def change do
    alter table(:dns_configs) do
      add :inbound_profile_id, references(:inbound_profiles, on_delete: :nilify_all)
    end
  end
end
