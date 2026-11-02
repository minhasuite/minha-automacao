# ondaB1 (B1): timers por voz (os do Assist do HA, que não são helpers): o
# satélite ou a pessoa que pediu, quanto falta e quando acaba.
class OndaB1Timers < ActiveRecord::Migration[8.1]
  def change
    create_table :assist_timers, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }, index: false
      t.uuid :satellite_id
      t.string :name
      t.integer :duration_s, null: false
      t.string :status, null: false, default: "active"
      t.datetime :ends_at
      t.integer :remaining_s
      t.timestamps
    end
    add_index :assist_timers, :tenant_id
  end
end
