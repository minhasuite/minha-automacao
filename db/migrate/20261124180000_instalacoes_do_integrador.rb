# Central do integrador (docs/PROPOSTA-integrador.md): as instalações acompanhadas, o último resumo de cada uma,
# os avisos ativos, o freio de versão e as amostras (temperatura, disco, memória) para os gráficos.
class InstalacoesDoIntegrador < ActiveRecord::Migration[8.1]
  def change
    create_table :installations, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :token_digest, null: false
      t.jsonb :last_report, null: false, default: {}
      t.datetime :last_seen_at
      t.string :status, null: false, default: "waiting"
      t.string :version_tag
      t.string :max_version
      t.jsonb :alerts, null: false, default: {}
      t.text :notes
      t.timestamps
    end
    add_index :installations, :token_digest, unique: true
    add_index :installations, %i[tenant_id name], unique: true

    create_table :installation_samples, id: false do |t|
      t.references :installation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.datetime :at, null: false
      t.integer :temp
      t.integer :cpu
      t.integer :memory
      t.integer :disk_used
      t.boolean :online
    end
    add_index :installation_samples, %i[installation_id at]
  end
end
