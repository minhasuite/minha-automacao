# Lote 5 da paridade com o HA (G9): atributos do ponto, os textos extras que
# o sensor calculado escreve além do valor (o `state_content`/atributo do HA),
# lidos no Liquid (`points["k"].attrs.nome`), na expressão (`k.attrs.nome`) e
# no widget Número/contador.
class Lote5AtributosDosPontos < ActiveRecord::Migration[8.1]
  def change
    add_column :points, :attrs, :jsonb, default: {}, null: false
  end
end
