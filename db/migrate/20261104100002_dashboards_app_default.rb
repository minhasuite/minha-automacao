# Painel padrão do app (a versão Mobile importada do HA), à parte do da web.
class DashboardsAppDefault < ActiveRecord::Migration[8.1]
  def change
    add_column :dashboards, :app_default, :boolean, default: false, null: false
  end
end
