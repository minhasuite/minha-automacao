# ondaC2 (C10): gravação própria das câmeras (contínua, por evento ou na
# hora), em arquivos MP4 no servidor; o banco guarda o índice para a linha do tempo.
class OndaC2Gravacoes < ActiveRecord::Migration[8.1]
  def change
    create_table :camera_recordings, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :point, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.datetime :started_at, null: false
      t.integer :duration_s, null: false, default: 0
      t.bigint :bytes, null: false, default: 0
      t.string :trigger, null: false, default: "continuous"
      t.string :file, null: false
      t.timestamps
    end
    add_index :camera_recordings, :tenant_id
    add_index :camera_recordings, :site_id
    add_index :camera_recordings, %i[point_id started_at]
  end
end
