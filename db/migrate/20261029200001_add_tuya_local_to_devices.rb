# F3: driver tuya_local. O segredo do aparelho (local_key da Tuya, token do
# Xiaomi depois) fica no próprio dispositivo, cifrado; `listen` liga o ouvinte
# persistente (desligado por padrão para não brigar com o HA até a migração).
# Sem tabela `integrations` por enquanto: nada do tuya_local é compartilhado
# entre aparelhos; ela entra com o primeiro driver de conta (nuvem, Alexa).
class AddTuyaLocalToDevices < ActiveRecord::Migration[8.1]
  def change
    add_column :devices, :credential, :text
    add_column :devices, :listen, :boolean, null: false, default: false
    add_index :devices, :external_id
  end
end
