# F1 (ESQUEMA-V1 §4.1 e §4.2): locais, áreas, papéis por local, dispositivos,
# pontos e etiquetas. Os filhos caem junto com o local (cascade no banco).
# `devices.driver` fica no dispositivo até as integrações (F3) chegarem.
class CreateSitesDevicesPoints < ActiveRecord::Migration[8.1]
  def change
    create_table :sites, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.string :kind, null: false, default: "home"
      t.string :timezone, null: false, default: "America/Sao_Paulo"
      t.string :address
      t.decimal :latitude, precision: 9, scale: 6
      t.decimal :longitude, precision: 9, scale: 6
      t.string :wallpaper
      t.timestamps
    end

    create_table :areas, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :parent, type: :uuid, foreign_key: { to_table: :areas, on_delete: :nullify }
      t.string :name, null: false
      t.string :kind, null: false, default: "room"
      t.string :icon
      t.string :background
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :site_memberships, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :role, null: false, default: "resident"
      t.uuid :area_ids, array: true, null: false, default: []
      t.datetime :expires_at
      t.timestamps
      t.index %i[site_id user_id], unique: true
    end

    create_table :devices, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :area, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :driver, null: false, default: "virtual"
      t.string :name, null: false
      t.string :manufacturer
      t.string :model
      t.string :serial
      t.string :external_id
      t.jsonb :address, null: false, default: {}
      t.string :firmware
      t.string :status, null: false, default: "online"
      t.datetime :last_seen_at
      t.uuid :battery_point_id
      t.boolean :disabled, null: false, default: false
      t.timestamps
    end

    create_table :points, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :device, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :area, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :key, null: false
      t.string :name, null: false
      t.string :icon
      t.string :capability, null: false
      t.string :data_type
      t.string :device_class
      t.string :state_class
      t.string :unit
      t.jsonb :options, null: false, default: []
      t.decimal :min
      t.decimal :max
      t.decimal :step
      t.boolean :writable, null: false, default: false
      t.jsonb :address, null: false, default: {}
      t.decimal :scale, null: false, default: 1
      t.decimal :offset, null: false, default: 0
      t.decimal :deadband
      t.string :history, null: false, default: "on_change"
      t.integer :history_interval_s
      t.integer :retention_days
      t.integer :pulse_ms
      t.integer :max_on_s
      t.string :confirm
      t.string :risk, null: false, default: "normal"
      t.jsonb :expose, null: false, default: {}
      t.jsonb :value
      t.string :quality, null: false, default: "good"
      t.datetime :changed_at
      t.datetime :reported_at
      t.boolean :hidden, null: false, default: false
      t.boolean :disabled, null: false, default: false
      t.timestamps
      t.index %i[site_id key], unique: true
    end

    create_table :tags, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.string :color
      t.timestamps
      t.index %i[tenant_id name], unique: true
    end

    create_table :taggings, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :tag, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :taggable, type: :uuid, polymorphic: true, null: false
      t.timestamps
      t.index %i[tag_id taggable_type taggable_id], unique: true, name: "index_taggings_uniqueness"
    end
  end
end
