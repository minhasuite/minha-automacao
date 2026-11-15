# mobile-ajustes: painel "Mostrar em" (app/web; NULL = pelo nome, ver Dashboard#show_in_effective)
# e painéis permitidos por pessoa no local (NULL = todos).
class PaineisPorSuperficieEPessoa < ActiveRecord::Migration[8.1]
  def change
    add_column :dashboards, :show_in, :string
    add_column :site_memberships, :dashboard_ids, :uuid, array: true
  end
end
