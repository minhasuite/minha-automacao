# F9: ajustes da instalação (liberação de endereços internos para a saída
# HTTP, cliente OAuth da Alexa).
class F9TenantSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :settings, :jsonb, null: false, default: {}
  end
end
