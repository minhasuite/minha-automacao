# Base do Minha Automação (padrão da suíte): empresa (tenant), usuários e
# papéis, tokens da API, convites, notificações, assinatura, auditoria e IA.
# O domínio de automação (ESQUEMA-V1) vem nas migrations seguintes. UUID em
# toda tabela.
class CreateCore < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pg_trgm"

    create_table :tenants, id: :uuid do |t|
      t.string :name, null: false
      t.string :trade_name
      t.string :document
      t.string :phone
      t.string :email
      t.string :city
      t.string :uf, limit: 2
      t.string :ibge_code, limit: 7
      t.string :plan, null: false, default: "free"
      t.string :plan_provider, limit: 20
      t.datetime :plan_expires_at
      t.timestamps
    end

    create_table :users, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.string :email, null: false
      t.string :password_digest
      t.string :google_uid
      t.string :role, null: false, default: "owner"
      t.timestamps
      t.index "lower(email)", unique: true, name: "index_users_on_lower_email"
      t.index :google_uid, unique: true, where: "google_uid IS NOT NULL"
    end

    create_table :api_tokens, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :access_token_digest, null: false
      t.string :refresh_token_digest, null: false
      t.string :previous_refresh_token_digest
      t.datetime :access_expires_at, null: false
      t.datetime :refresh_expires_at, null: false
      t.string :device_name
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
      t.index :access_token_digest, unique: true
      t.index :refresh_token_digest, unique: true
      t.index :previous_refresh_token_digest
    end

    create_table :service_api_keys, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :scopes, array: true, null: false, default: []
      t.datetime :expires_at
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
      t.index :token_digest, unique: true
    end

    create_table :invites, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :created_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :accepted_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :role, null: false, default: "member"
      t.string :code_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.timestamps
      t.index :code_digest, unique: true
    end

    create_table :device_tokens, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :token, null: false
      t.string :platform, null: false, default: "android"
      t.datetime :last_seen_at
      t.timestamps
      t.index :token, unique: true
    end

    create_table :notifications, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, foreign_key: { on_delete: :cascade } # nulo = para os administradores da empresa
      t.string :kind, null: false
      t.string :title, null: false
      t.string :body
      t.jsonb :data, null: false, default: {}
      t.string :dedup_key
      t.datetime :read_at
      t.timestamps
      t.index %i[tenant_id dedup_key], unique: true, where: "dedup_key IS NOT NULL"
      t.index %i[tenant_id created_at]
    end

    create_table :subscriptions, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :source, null: false, limit: 20
      t.string :external_id, null: false
      t.string :product_id, limit: 100
      t.string :base_plan_id, limit: 100
      t.string :offer_id, limit: 100
      t.string :plan, null: false, default: "free", limit: 20
      t.string :status, null: false, limit: 20
      t.boolean :auto_renewing
      t.boolean :trial, null: false, default: false
      t.datetime :expires_at
      t.string :linked_external_id
      t.datetime :verified_at
      t.timestamps
      t.index %i[source external_id], unique: true
    end

    create_table :audit_events, id: :uuid do |t|
      t.references :tenant, type: :uuid, foreign_key: { on_delete: :cascade }
      t.uuid :user_id
      t.string :action, null: false
      t.string :auditable_type, null: false
      t.uuid :auditable_id
      t.jsonb :details, null: false, default: {}
      t.datetime :created_at, null: false
      t.index %i[auditable_type auditable_id]
    end

    # ---- IA (cota e configuração) -----------------------------------------

    create_table :ai_usages, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.string :feature, null: false
      t.date :period, null: false
      t.integer :count, null: false, default: 0
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.string :model
      t.timestamps
      t.index %i[tenant_id feature period], unique: true
    end

    create_table :ai_tier_configs, id: :uuid do |t|
      t.string :tier, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.string :effort
      t.timestamps
      t.index :tier, unique: true
    end

    create_table :ai_plan_features, id: :uuid do |t|
      t.string :feature, null: false
      t.string :plan, null: false
      t.string :tier
      t.integer :limit
      t.boolean :available, null: false, default: true
      t.timestamps
      t.index %i[feature plan], unique: true
    end

    create_table :model_prices, id: :uuid do |t|
      t.string :provider, null: false
      t.string :model, null: false
      t.decimal :input_per_mtok, precision: 10, scale: 4, null: false, default: 0
      t.decimal :output_per_mtok, precision: 10, scale: 4, null: false, default: 0
      t.timestamps
      t.index %i[provider model], unique: true
    end

    create_table :feature_flags, id: :uuid do |t|
      t.string :key, null: false
      t.boolean :enabled, null: false, default: true
      t.timestamps
      t.index :key, unique: true
    end
  end
end
