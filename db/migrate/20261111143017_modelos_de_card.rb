# P1.3 da proposta de personalização: modelos de card declarativos por local.
# Um modelo diz o desenho (`layout`, só os que existem no componentes-ui e no
# app), os espaços (`slots`: Liquid, consulta + conta ou regra) e as entradas
# (`params`, o que o widget preenche em `vars`). Nunca código: o servidor
# resolve tudo para o mesmo `data` que a web e o app desenham.
class ModelosDeCard < ActiveRecord::Migration[8.1]
  def change
    create_table :card_templates, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :key, null: false
      t.string :name, null: false
      t.string :description
      t.string :layout, null: false
      t.jsonb :slots, null: false, default: {}
      t.jsonb :params, null: false, default: []
      t.integer :version, null: false, default: 1
      t.string :source
      t.timestamps
    end
    add_index :card_templates, %i[site_id key], unique: true
    add_index :card_templates, :tenant_id
  end
end
