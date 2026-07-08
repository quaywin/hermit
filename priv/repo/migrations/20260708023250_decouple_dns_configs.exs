defmodule Hermit.Repo.Migrations.DecoupleDnsConfigs do
  use Ecto.Migration

  def up do
    # 1. Drop index unique cũ trên dns_configs
    drop_if_exists index(:dns_configs, [:inbound_profile_id])

    # 2. Xóa cột inbound_profile_id trên dns_configs
    alter table(:dns_configs) do
      remove :inbound_profile_id
      add :name, :string, null: false, default: "Default DNS Profile"
    end

    # 3. Thêm khóa ngoại dns_profile_id vào inbound_profiles
    alter table(:inbound_profiles) do
      add :dns_profile_id, references(:dns_configs, on_delete: :nilify_all)
    end
  end

  def down do
    alter table(:inbound_profiles) do
      remove :dns_profile_id
    end

    alter table(:dns_configs) do
      remove :name
      add :inbound_profile_id, references(:inbound_profiles, on_delete: :nilify_all)
    end

    create unique_index(:dns_configs, [:inbound_profile_id])
  end
end
