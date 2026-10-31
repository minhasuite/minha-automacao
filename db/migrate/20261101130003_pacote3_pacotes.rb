# Pacote 3: loja de pacotes declarativos (como o HACS, sem código de
# terceiros). Um pacote instalado guarda o manifesto da versão em uso e o
# que ele pôs nos registros do local (blueprints, helpers, painéis); os mapas
# de dados ficam no próprio manifesto (DeviceMaps lê daqui).
class Pacote3Pacotes < ActiveRecord::Migration[8.1]
  def change
    create_table :packages, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :key, null: false
      t.string :name, null: false
      t.string :version, null: false
      t.string :source_url, null: false
      t.jsonb :manifest, null: false, default: {}
      t.jsonb :installed, null: false, default: []
      t.timestamps
    end
    add_index :packages, %i[site_id key], unique: true
    add_index :packages, :tenant_id
  end
end
