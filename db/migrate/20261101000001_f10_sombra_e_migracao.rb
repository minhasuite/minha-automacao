# F10: modo sombra (automação, script, cena e local; o global fica em
# `tenants.settings["shadow"]`), o que a sombra "teria feito", o de-para com o
# sistema de origem de uma migração e os relatórios do comparador.
class F10SombraEMigracao < ActiveRecord::Migration[8.1]
  def change
    add_column :automations, :shadow, :boolean, null: false, default: false
    add_column :scenes, :shadow, :boolean, null: false, default: false
    add_column :sites, :shadow, :boolean, null: false, default: false
    add_column :automation_runs, :shadow, :boolean, null: false, default: false

    # Uma linha por ação que a sombra segurou (ou executou, se for interna).
    create_table :shadow_actions, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :automation, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :automation_run, type: :uuid, foreign_key: { on_delete: :nullify }, index: false
      t.references :scene, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :action, null: false
      t.string :title, null: false
      t.string :detail
      t.jsonb :effects, null: false, default: []
      t.boolean :executed, null: false, default: false
      t.datetime :created_at, null: false
    end
    add_index :shadow_actions, %i[site_id created_at]

    # De-para: id no sistema de origem (entidade, aparelho, automação...) → registro daqui.
    create_table :external_refs, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :source, null: false
      t.string :external_id, null: false
      t.string :kind, null: false
      t.string :name
      t.string :target_type
      t.uuid :target_id
      t.string :note
      t.timestamps
    end
    add_index :external_refs, %i[site_id source external_id], unique: true
    add_index :external_refs, %i[target_type target_id]

    create_table :shadow_reports, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :source, null: false
      t.datetime :window_from, null: false
      t.datetime :window_to, null: false
      t.jsonb :summary, null: false, default: {}
      t.jsonb :rows, null: false, default: []
      t.datetime :created_at, null: false
    end
    add_index :shadow_reports, %i[site_id created_at]
  end
end
