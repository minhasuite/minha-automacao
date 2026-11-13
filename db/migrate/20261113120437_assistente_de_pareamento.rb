# Assistente de pareamento (docs/integracoes.md, "Zigbee"): o estado da ponte
# de cada protocolo por local (pareamento aberto até quando, informação da
# ponte, último mapa de rede) e os aparelhos que entraram pelo assistente
# (entrou → entrevista → decidido: novo ou substitui um existente). Genérico:
# `protocol` é a chave do plugin de integração que pareia (hoje zigbee2mqtt).
class AssistenteDePareamento < ActiveRecord::Migration[8.1]
  def change
    create_table :pairing_bridges, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :protocol, null: false
      t.string :state
      t.datetime :permit_until
      t.jsonb :info, null: false, default: {}
      t.jsonb :network_map
      t.datetime :network_map_at
      t.datetime :network_map_requested_at
      t.string :network_map_error
      t.timestamps
    end
    add_index :pairing_bridges, %i[site_id protocol], unique: true
    add_index :pairing_bridges, :tenant_id

    create_table :pairing_joins, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :device, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
      t.string :protocol, null: false
      t.string :external_id, null: false
      t.string :name
      t.string :status, null: false, default: "joined"
      t.string :model
      t.string :manufacturer
      t.string :description
      t.string :power_source
      t.boolean :supported
      t.string :resolution
      t.datetime :resolved_at
      t.datetime :joined_at, null: false
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
    add_index :pairing_joins, %i[site_id protocol external_id], unique: true
    add_index :pairing_joins, :tenant_id
  end
end
