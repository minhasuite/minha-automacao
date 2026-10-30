module Points
  # Valor bruto empacotado → valor do ponto, dirigido pelo endereço do ponto
  # (vem do mapa de dados, ex.: config/device_maps/tuya.yml), sem código por
  # aparelho. `decode` escolhe o decodificador em DECODERS; `field` pega um
  # campo do resultado; `match` transforma em verdadeiro quando o campo vale
  # isso (e nil = "não é comigo", o ponto não muda). Ex.: o dp
  # `initiative_message` da câmera Tuya é base64 de um JSON com `cmd:
  # ipc_motion` no movimento. Decodificador novo = uma linha em DECODERS.
  module Decode
    DECODERS = {
      "base64_json" => ->(raw) { JSON.parse(Base64.decode64(raw.to_s)) },
      "json" => ->(raw) { raw.is_a?(String) ? JSON.parse(raw) : raw }
    }.freeze

    module_function

    def call(address, raw)
      value = DECODERS.fetch(address["decode"]).call(raw)
      value = value.is_a?(Hash) ? value.dig(*address["field"].to_s.split(".")) : nil if address["field"].present?
      return value unless address.key?("match")

      true if value.to_s == address["match"].to_s
    rescue JSON::ParserError, ArgumentError, KeyError, TypeError
      nil
    end
  end
end
