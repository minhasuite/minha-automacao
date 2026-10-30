# F8: leitura periódica (só leitura) por dispositivo (tuya_local, xiaomi_miot)
# e por integração (Alexa: lista de Echo). Padrão 30 min; nulo ou 0 desliga.
# `polled_at` = última tentativa (sucesso ou não).
class AddPolling < ActiveRecord::Migration[8.1]
  def change
    add_column :devices, :poll_s, :integer, default: 1800
    add_column :devices, :polled_at, :datetime
    add_column :integrations, :poll_s, :integer, default: 1800
    add_column :integrations, :polled_at, :datetime
  end
end
