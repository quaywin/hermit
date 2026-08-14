defmodule Hermit.Repo.Migrations.AddDdnsHostnameToDnsEndpoints do
  use Ecto.Migration

  def change do
    alter table(:dns_endpoints) do
      add(:ddns_hostname, :string)
    end
  end
end
