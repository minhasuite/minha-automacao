# ondaA1 (A4, paridade 1.11): configuração geral do local como no HA
# (sistema de unidades, moeda, elevação, país e idioma) e a unidade de
# exibição por ponto (conversão só na tela).
class OndaA1Unidades < ActiveRecord::Migration[8.1]
  def change
    change_table :sites, bulk: true do |t|
      t.string :unit_system, null: false, default: "metric"
      t.string :currency, null: false, default: "BRL"
      t.integer :elevation
      t.string :country, default: "BR"
      t.string :language
    end
    add_column :points, :display_unit, :string
  end
end
