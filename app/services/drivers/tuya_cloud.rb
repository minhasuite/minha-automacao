module Drivers
  # Tuya pela nuvem (conta Smart Life da integração), como a integração `tuya`
  # do HA: serve aos aparelhos sem controle local (Zigbee atrás do hub,
  # câmera, fechadura) e a qualquer outro da conta. Comando = código do dp no
  # endereço do ponto (`address.code`) com o valor bruto; o eco chega pelo
  # MQTT (Tuya::CloudListener) e, até lá, o ponto fica com o valor pedido.
  class TuyaCloud
    class Error < StandardError; end

    # Grava nos pontos o estado da nuvem ({código ou dpId → valor bruto}).
    # `push` = veio pelo MQTT (conta ponto `push_only`, como evento de botão).
    def self.report(device, state, push: false, at: Time.current)
      dps = state.to_h do |k, v|
        p = device.points.find { |pt| pt.address["code"] == k.to_s }
        [ p ? p.address["dps"].to_s : k.to_s, v ]
      end
      TuyaLocal.report(device, dps, at: at, push: push)
    end

    def self.cloud_for(device)
      integration = device.integration or raise Error, "Aparelho sem conta Tuya ligada: sincronize a integração."
      Tuya::Cloud.new(integration)
    end

    def execute(point, command, value)
      code = point.address["code"].presence or raise Error, "Ponto sem código Tuya no endereço: sincronize a integração."
      new_value = Points::Command.new(point, command, value).new_value
      writes = point.raw_writes(new_value, "tuya_cloud")&.map { |a, raw| { "code" => a["code"], "value" => raw } } || [ { "code" => code, "value" => point.to_raw(new_value) } ]
      self.class.cloud_for(point.device).commands(point.device.external_id, writes)
      point.report!(new_value)
    end
  end
end
