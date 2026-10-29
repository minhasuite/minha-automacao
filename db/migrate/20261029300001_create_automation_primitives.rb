# F4 (ESQUEMA-V1 §4.2 e §4.5): primitivas declarativas de automação.
# Espelhamento, agenda, cena, aviso e alerta com escalonamento. Tudo cai junto
# com o local ou o ponto (cascade no banco).
class CreateAutomationPrimitives < ActiveRecord::Migration[8.1]
  def change
    # Comando disparado por espelhamento: de qual ponto veio (anti-eco).
    add_column :commands, :origin_point_id, :uuid

    create_table :point_links, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :source_point, type: :uuid, null: false, foreign_key: { to_table: :points, on_delete: :cascade }
      t.references :target_point, type: :uuid, null: false, foreign_key: { to_table: :points, on_delete: :cascade }
      t.string :mode, null: false, default: "mirror"
      t.boolean :bidirectional, null: false, default: false
      t.jsonb :trigger_value
      t.boolean :enabled, null: false, default: true
      t.timestamps
      t.index %i[source_point_id target_point_id], unique: true
    end

    create_table :scenes, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :icon
      t.jsonb :items, null: false, default: []
      t.timestamps
    end

    create_table :schedules, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :point, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :scene, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :command
      t.jsonb :value
      t.string :kind, null: false, default: "time"
      t.string :time_of_day
      t.integer :offset_min, null: false, default: 0
      t.integer :days, array: true, null: false, default: [ 0, 1, 2, 3, 4, 5, 6 ]
      t.boolean :enabled, null: false, default: true
      t.datetime :next_run_at
      t.datetime :last_run_at
      t.timestamps
      t.index :next_run_at, where: "enabled"
    end

    create_table :notify_rules, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :point, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.jsonb :to_value
      t.string :message
      t.string :channels, array: true, null: false, default: %w[in_app push]
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    create_table :alert_rules, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :point, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :operator, null: false, default: "eq"
      t.jsonb :value
      t.integer :for_s, null: false, default: 0
      t.string :severity, null: false, default: "warning"
      t.jsonb :escalation, null: false, default: []
      t.integer :repeat_s
      t.boolean :auto_resolve, null: false, default: true
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    create_table :alerts, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :alert_rule, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :point, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :level, null: false, default: 0
      t.datetime :opened_at, null: false
      t.references :acked_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :acked_at
      t.datetime :resolved_at
      t.timestamps
      # Um alerta aberto por regra.
      t.index :alert_rule_id, unique: true, where: "resolved_at IS NULL", name: "index_alerts_open_per_rule"
      t.index %i[alert_rule_id opened_at]
    end
  end
end
