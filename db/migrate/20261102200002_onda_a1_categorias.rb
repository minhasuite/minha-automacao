# ondaA1 (A2, paridade 1.4): categoria por lista (automações, scripts, cenas
# e helpers), para agrupar em blocos recolhíveis como no HA.
class OndaA1Categorias < ActiveRecord::Migration[8.1]
  def change
    add_column :automations, :category, :string
    add_column :scenes, :category, :string
    add_column :points, :category, :string
  end
end
