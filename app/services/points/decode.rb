module Points
  # Valor bruto empacotado → valor do ponto, dirigido pelo endereço do ponto
  # (vem do mapa de dados, ex.: config/device_maps/tuya.yml), sem código por
  # aparelho. `decode` escolhe o decodificador em DECODERS; `field` pega um
  # campo do resultado; `match` transforma em verdadeiro quando o campo vale
  # isso (e nil = "não é comigo", o ponto não muda). Ex.: o dp
  # `initiative_message` da câmera Tuya é base64 de um JSON com `cmd:
  # ipc_motion` no movimento. `unmatched` = valor quando não casa (enum
  # `pir`/`none` → verdadeiro/falso). Decodificador novo = uma linha em DECODERS.
  # `invert` (genérico, qualquer driver que lê por `Point#from_raw`/`to_raw` e o
  # MQTT): troca verdadeiro ↔ falso na leitura e no comando de ponto bool (ex.:
  # contato em que o bruto verdadeiro = fechado; "Substituir aparelho").
  module Decode
    DECODERS = {
      "base64_json" => ->(raw) { JSON.parse(Base64.decode64(raw.to_s)) },
      "json" => ->(raw) { raw.is_a?(String) ? JSON.parse(raw) : raw },
      "value" => ->(raw) { raw }
    }.freeze

    module_function

    # Verdadeiro ↔ falso quando o endereço pede (`invert`); o resto passa igual.
    def invert(address, value) = flip(value, address.to_h["invert"])
    def flip(value, on) = on && [ true, false ].include?(value) ? !value : value

    def call(address, raw)
      value = DECODERS.fetch(address["decode"]).call(raw)
      value = value.is_a?(Hash) ? value.dig(*address["field"].to_s.split(".")) : nil if address["field"].present?
      return value unless address.key?("match")

      return true if value.to_s == address["match"].to_s

      address["unmatched"]
    rescue JSON::ParserError, ArgumentError, KeyError, TypeError
      nil
    end
  end
end
