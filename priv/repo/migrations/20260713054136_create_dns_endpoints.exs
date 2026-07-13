defmodule Hermit.Repo.Migrations.CreateDnsEndpoints do
  use Ecto.Migration

  def up do
    # 1. Tạo bảng dns_endpoints
    create table(:dns_endpoints) do
      add :name, :string, null: false
      add :doh_token, :string, null: false
      add :dns_profile_id, references(:dns_configs, on_delete: :nilify_all)
      add :inbound_profile_id, references(:inbound_profiles, on_delete: :nilify_all)
      add :enabled, :boolean, default: false, null: false

      timestamps()
    end

    create unique_index(:dns_endpoints, [:doh_token])
    create index(:dns_endpoints, [:dns_profile_id])
    create index(:dns_endpoints, [:inbound_profile_id])

    # 2. Thực hiện data migration để chuyển đổi dữ liệu từ inbound_profiles sang dns_endpoints
    flush()

    execute fn ->
      # Lấy dữ liệu trực tiếp bằng câu lệnh SQL thô để tránh phụ thuộc vào Ecto schemas
      results = repo().query!("SELECT id, name, doh_token, dns_profile_id FROM inbound_profiles WHERE dns_profile_id IS NOT NULL", [])

      Enum.each(results.rows, fn [id, name, doh_token, dns_profile_id] ->
        token = doh_token || (:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false))
        repo().query!(
          "INSERT INTO dns_endpoints (name, doh_token, dns_profile_id, inbound_profile_id, enabled, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
          ["Endpoint for #{name}", token, dns_profile_id, id, 1]
        )
      end)
    end

    # Drop index trên inbound_profiles trước khi xóa cột doh_token
    drop_if_exists index(:inbound_profiles, [:doh_token])

    # 3. Xóa các cột liên quan đến DNS trong inbound_profiles
    alter table(:inbound_profiles) do
      remove :dns_profile_id
      remove :doh_token
    end
  end

  def down do
    # 1. Khôi phục các cột trong inbound_profiles
    alter table(:inbound_profiles) do
      add :dns_profile_id, references(:dns_configs, on_delete: :nilify_all)
      add :doh_token, :string
    end

    create unique_index(:inbound_profiles, [:doh_token])

    flush()

    # 2. Khôi phục dữ liệu ngược lại
    execute fn ->
      results = repo().query!("SELECT inbound_profile_id, doh_token, dns_profile_id FROM dns_endpoints WHERE inbound_profile_id IS NOT NULL", [])

      Enum.each(results.rows, fn [inbound_profile_id, doh_token, dns_profile_id] ->
        repo().query!(
          "UPDATE inbound_profiles SET doh_token = $1, dns_profile_id = $2 WHERE id = $3",
          [doh_token, dns_profile_id, inbound_profile_id]
        )
      end)
    end

    # 3. Xóa bảng dns_endpoints
    drop table(:dns_endpoints)
  end
end
