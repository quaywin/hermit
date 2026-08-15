defmodule Hermit.Repo.Migrations.AddEnableDdnsFilterToDnsEndpoints do
  use Ecto.Migration

  def change do
    alter table(:dns_endpoints) do
      add :enable_ddns_filter, :boolean, default: true
    end
  end
end
