# Helpers (F8e): ponto virtual com um tipo de helper (HelperTypes::PLUGINS);
# a configuração do tipo fica em `points.address`.
class AddPointHelper < ActiveRecord::Migration[8.1]
  def change
    add_column :points, :helper, :string
    add_index :points, %i[site_id helper], where: "helper IS NOT NULL"
  end
end
