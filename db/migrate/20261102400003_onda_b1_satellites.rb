# ondaB1 (B6): satélites de voz (Wyoming, ESPHome) numa área, com pipeline e
# papel próprios.
class OndaB1Satellites < ActiveRecord::Migration[8.1]
  def change
    create_table :assist_satellites, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :area, type: :uuid, foreign_key: { on_delete: :nullify }, index: false
      t.references :pipeline, type: :uuid, foreign_key: { to_table: :assist_pipelines, on_delete: :nullify }, index: false
      t.references :device, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
      t.string :name, null: false
      t.string :kind, null: false
      t.string :host
      t.integer :port
      t.string :role, null: false, default: "resident"
      t.boolean :enabled, null: false, default: true
      t.datetime :last_seen_at
      t.string :last_error
      t.timestamps
    end
    add_index :assist_satellites, :tenant_id
  end
end
