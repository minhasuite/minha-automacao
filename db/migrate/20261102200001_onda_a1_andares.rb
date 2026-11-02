# ondaA1 (A1, paridade 1.2): andar com nível (subsolo -1, térreo 0, 1º 1...),
# para ordenar, agrupar e mirar ("apague o térreo", consulta `floor=`).
class OndaA1Andares < ActiveRecord::Migration[8.1]
  def change
    add_column :areas, :level, :integer
  end
end
