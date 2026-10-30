# F8f: scripts (automação de `kind: "script"`, com campos), blueprints
# (modelos com entradas tipadas; a automação criada guarda o vínculo e as
# entradas) e rótulos nas automações (Tagging polimórfico de sempre).
class F8fScriptsBlueprints < ActiveRecord::Migration[8.1]
  def change
    create_table :blueprints, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.text :description
      t.string :domain, null: false, default: "automation"
      t.string :mode, null: false, default: "single"
      t.jsonb :inputs, null: false, default: []
      t.jsonb :definition, null: false, default: {}
      t.string :source, null: false, default: "manual"
      t.string :source_url
      t.jsonb :unsupported, null: false, default: []
      t.integer :version, null: false, default: 1
      t.timestamps
      t.index %i[site_id source], unique: true, where: "source LIKE 'builtin:%'"
    end

    add_column :automations, :kind, :string, null: false, default: "automation"
    add_column :automations, :fields, :jsonb, null: false, default: []
    add_column :automations, :icon, :string
    add_reference :automations, :blueprint, type: :uuid, foreign_key: { on_delete: :nullify }
    add_column :automations, :blueprint_inputs, :jsonb
    add_column :automations, :blueprint_version, :integer
    add_index :automations, %i[site_id kind]
  end
end
