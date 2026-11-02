# integ: pontes de exposição (Matter e as próximas). Um registro por ponto
# exposto numa ponte, com o nome que o outro ecossistema mostra.
class IntegPontesDeExposicao < ActiveRecord::Migration[8.1]
  def change
    create_table :bridge_exposures, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :point, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :bridge, null: false
      t.string :name
      t.timestamps
    end
    add_index :bridge_exposures, %i[point_id bridge], unique: true
    add_index :bridge_exposures, %i[site_id bridge]
    add_index :bridge_exposures, :tenant_id
  end
end
