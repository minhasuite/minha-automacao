# F2 (ESQUEMA-V1 §4.4): comandos rastreados, leituras particionadas por mês,
# rollups de hora e dia e eventos. Tudo cai junto com o ponto (cascade).
class CreateHistory < ActiveRecord::Migration[8.1]
  def up
    create_table :commands, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :point, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :command, null: false
      t.jsonb :value
      t.string :source, null: false, default: "api"
      t.string :status, null: false, default: "pending"
      t.string :error
      t.uuid :client_uuid
      t.datetime :sent_at
      t.datetime :confirmed_at
      t.timestamps
      t.index %i[point_id created_at], order: { created_at: :desc }
      t.index %i[tenant_id client_uuid], unique: true, where: "client_uuid IS NOT NULL"
    end

    create_table :events, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :point, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
      t.string :kind, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :source
      t.datetime :at, null: false
      t.index %i[point_id at], order: { at: :desc }
    end

    # Particionada por mês (partição nativa). `readings_default` segura o que
    # cair fora das partições criadas (job parado), para não perder leitura.
    execute <<~SQL
      CREATE TABLE readings (
        point_id uuid NOT NULL REFERENCES points(id) ON DELETE CASCADE,
        at timestamp(6) NOT NULL,
        value numeric,
        value_text text
      ) PARTITION BY RANGE (at);
      CREATE INDEX index_readings_on_point_id_and_at ON readings (point_id, at DESC);
      CREATE TABLE readings_default PARTITION OF readings DEFAULT;
    SQL
    Reading.ensure_partitions!

    create_table :reading_rollups, id: false do |t|
      t.references :point, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :bucket, null: false
      t.datetime :starts_at, null: false
      t.decimal :min
      t.decimal :max
      t.decimal :avg
      t.decimal :sum
      t.decimal :last
      t.integer :count, null: false, default: 0
      t.integer :on_seconds
      t.index %i[point_id bucket starts_at], unique: true, name: "index_reading_rollups_uniqueness"
    end
  end

  def down
    drop_table :reading_rollups
    execute "DROP TABLE readings CASCADE"
    drop_table :events
    drop_table :commands
  end
end
