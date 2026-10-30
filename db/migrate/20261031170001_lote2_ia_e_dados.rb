# Lote 2 da paridade com o HA: IA da instalação (chaves próprias por
# provedor, registro de cada chamada e limite mensal) e conjuntos de dados
# que as automações gravam e consultam (no lugar do shell_command + sql).
class Lote2IaEDados < ActiveRecord::Migration[8.1]
  def change
    # Uma conta por provedor (plugin de Ai::PROVIDERS); a chave é cifrada.
    create_table :ai_accounts, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.string :provider, null: false
      t.text :api_key
      t.string :base_url
      t.string :model
      t.boolean :enabled, null: false, default: true
      t.datetime :last_ok_at
      t.string :last_error
      t.timestamps
    end
    add_index :ai_accounts, %i[tenant_id provider], unique: true

    # Uma linha por chamada (sem prompt nem resposta): custo e origem.
    create_table :ai_calls, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :automation, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :source, null: false
      t.string :provider, null: false
      t.string :model
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.decimal :cost, precision: 12, scale: 6, null: false, default: 0
      t.string :status, null: false
      t.string :error
      t.integer :duration_ms
      t.datetime :created_at, null: false
    end
    add_index :ai_calls, %i[tenant_id created_at]

    create_table :datasets, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :key, null: false
      t.jsonb :fields, null: false, default: []
      t.integer :retention_days
      t.timestamps
    end
    add_index :datasets, %i[site_id key], unique: true

    create_table :dataset_records, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :dataset, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.jsonb :data, null: false, default: {}
      t.uuid :automation_run_id
      t.datetime :created_at, null: false
    end
    add_index :dataset_records, %i[dataset_id created_at]
  end
end
