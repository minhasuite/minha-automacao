# F5 (ESQUEMA-V1 §4.6 e §6): dashboards dirigidos pelo servidor. `definition`
# é a versão publicada (JSON da §6.1), `draft` o rascunho do editor; cada
# publicação vira uma linha em `dashboard_versions` (voltar versão). `auto`:
# gerado a partir das áreas e pontos até alguém publicar uma edição.
class CreateDashboards < ActiveRecord::Migration[8.1]
  def change
    create_table :dashboards, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :kind, null: false, default: "custom"
      t.boolean :auto, null: false, default: false
      t.boolean :site_default, null: false, default: false
      t.jsonb :definition, null: false, default: {}
      t.jsonb :draft
      t.integer :schema_version, null: false, default: 1
      t.integer :version, null: false, default: 0
      t.string :roles, array: true, null: false, default: []
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :dashboard_versions, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :dashboard, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :author, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :version, null: false
      t.jsonb :definition, null: false
      t.datetime :created_at, null: false
      t.index %i[dashboard_id version], unique: true
    end

    # Painel padrão da pessoa: {"site" => site_id, "<site_id>" => dashboard_id}.
    add_column :users, :dashboard_prefs, :jsonb, null: false, default: {}
  end
end
