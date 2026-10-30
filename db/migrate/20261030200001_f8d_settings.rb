# F8d: Configurações da instalação. Pessoa desativada (`disabled_at`), convite
# por link com local e papel, chave de integração por local, painel no menu
# lateral com ícone e o "Novo" do dispositivo só para o adotado de uma conta.
class F8dSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :disabled_at, :datetime
    add_column :invites, :site_id, :uuid
    add_column :invites, :site_role, :string
    add_column :service_api_keys, :site_ids, :uuid, array: true, null: false, default: []
    add_column :dashboards, :icon, :string
    add_column :dashboards, :sidebar, :boolean, null: false, default: false
    add_column :devices, :discovered_at, :datetime
  end
end
