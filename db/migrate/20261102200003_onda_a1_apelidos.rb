# ondaA1 (A3, paridade 1.9): apelidos de ponto e de área (andar é área),
# usados pela voz, pela busca e pela tela Expor.
class OndaA1Apelidos < ActiveRecord::Migration[8.1]
  def change
    add_column :points, :aliases, :string, array: true, default: [], null: false
    add_column :areas, :aliases, :string, array: true, default: [], null: false
  end
end
