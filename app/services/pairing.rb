# Assistente de pareamento e saúde da rede de malha (docs/integracoes.md,
# "Zigbee"), aberto a outros protocolos: a capacidade é do plugin de
# integração (`Integrations::Plugin.pairing_bridge` → adaptador `< Pairing::Adapter`).
# Telas, sugestão de substituição, desenho do mapa e a regra do nome são
# daqui; o adaptador só fala com a ponte (abrir/fechar, renomear, pedir o
# mapa, dizer quem é dele). Hoje: zigbee2mqtt (`Mqtt::Z2m::Bridge`).
module Pairing
  module_function

  def adapters = Integrations.plugins.filter_map(&:pairing_bridge).uniq
  def adapter(key) = adapters.find { |a| a.key == key.to_s }
  # Os que valem para o local (ponte ouvida ou aparelhos dela no local).
  def for_site(site) = adapters.select { |a| a.available?(site) }
  def for_device(device) = adapters.find { |a| a.owns?(device) }

  # A pessoa renomeou um aparelho da ponte (web, API ou app): o nome vai para
  # a ponte, para a próxima descoberta não trazer o antigo de volta. Fica
  # pendente (`address.rename_to`) até a ponte confirmar; sem broker agora, o
  # ouvinte manda de novo ao reconectar e a descoberta não sobrescreve.
  def renamed(device)
    adapter = for_device(device) or return
    device.update_columns(address: device.address.except("rename_error").merge("rename_to" => device.name, "rename_at" => Time.current.iso8601))
    adapter.rename!(device, device.name)
  rescue Drivers::Mqtt::Error => e
    Rails.logger.warn("[pairing] renomear #{device.id}: #{e.message} (fica pendente)")
  end

  # Erro do nome para a ponte (nil = ok); vira erro de validação do aparelho.
  def name_error(device, name) = for_device(device)&.name_error(name)

  # Informação de malha que a descoberta grava no aparelho (`address.mesh`):
  # role (coordinator/router/end_device), power (battery/mains), lqi, lqi_at.
  def mesh(device) = device.address.to_h["mesh"].to_h
end
