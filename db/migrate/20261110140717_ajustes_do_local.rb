# Painel aberto por dado (P1.1 e ideia 22 da proposta de personalização): os
# padrões do local que hoje eram regra fixa no código. `settings` guarda
# `dashboard_defaults` (`area_facts`: os itens do cartão de área como
# consultas; `stale_after_min`: limite do selo "dado velho" por tipo). Ver
# docs/dashboards.md.
class AjustesDoLocal < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :settings, :jsonb, default: {}, null: false
  end
end
