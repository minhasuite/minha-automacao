module Drivers
  # MQTT genérico (o Mosquitto do servidor local; o zigbee2mqtt é um caso dele).
  # Ponto ↔ tópico por `points.address`: `topic` (estado), `json_path` ("a.b";
  # vazio = o payload inteiro), `command_topic` (padrão `topic/set`),
  # `payload_on`/`payload_off` (padrão true/false). Número: bruto × scale +
  # offset (`command_json_path` troca o caminho só no comando). O valor entra pelo `Mqtt::Listener` quando o aparelho publica o
  # estado; o comando só publica (o eco do estado atualiza o ponto), salvo
  # ponto sem tópico de estado, que é atualizado na hora.
  # ondaC1 (C4, descoberta do HA): `value_template`/`command_template` (Jinja do
  # HA), `value_map`/`payload_map` (estado ↔ valor), `state_on`/`state_off`
  # (estado diferente do comando), `payload_press` (botão) e `retain`.
  # resto: `command_map` (nome do comando → payload: robô), `payload_install`
  # (firmware) e `image` ("mqtt": o payload é o JPEG da câmera, guardado como quadro).
  # `invert`: ponto bool com o sentido trocado (Points::Decode.invert).
  class Mqtt
    class Error < StandardError; end

    def self.url = ENV["MQTT_URL"].presence

    def execute(point, command, value)
      a = point.address
      topic = a["command_topic"].presence || (a["topic"].present? && "#{a['topic']}/set") or raise Error, "Ponto sem tópico no endereço."
      return ::Mqtt::Listener.publish(topic, a["command_map"].fetch(command) { raise Error, "Comando sem payload: #{command}." }.to_s) if a["command_map"].is_a?(Hash)

      new_value = Points::Command.new(point, command, value).new_value
      ::Mqtt::Listener.publish(topic, self.class.payload(point, new_value), **(a["retain"] ? { retain: true } : {}))
      point.report!(new_value) if a["topic"].blank?
    end

    # Valor do ponto → payload publicado.
    def self.payload(point, value)
      a = point.address
      return a["payload_press"].to_s if a.key?("payload_press")
      return a["payload_map"][value.to_s].to_s if a["payload_map"].is_a?(Hash) && a["payload_map"].key?(value.to_s)

      return plain_payload(point, value) if a["command_template"].blank?

      ::Mqtt::HaDiscovery.render(a["command_template"], value.is_a?(Numeric) ? raw_number(point, value) : value).to_s
    end

    # Número sem calibração num ponto decimal vai como está (21.5, não 22).
    def self.raw_number(point, value)
      point.data_type == "decimal" && point.scale.to_d == 1 && point.offset.to_d.zero? ? value : point.to_raw(value)
    end

    def self.plain_payload(point, value)
      a = point.address
      raw = if point.bool?
        ::Points::Decode.invert(a, value) ? a.fetch("payload_on", true) : a.fetch("payload_off", false)
      else
        point.numeric? ? raw_number(point, value) : point.to_raw(value)
      end
      # Pacote 1: `command_json_path` (mesmo vazio) vale para o comando; Tasmota lê o JSON e recebe "ON" puro.
      path = (a.key?("command_json_path") ? a["command_json_path"] : a["json_path"]).presence or return raw.is_a?(String) ? raw : raw.to_json
      path.split(".").reverse.reduce(raw) { |acc, k| { k => acc } }.to_json
    end

    # Payload recebido → valor do ponto; nil = a mensagem não traz o campo.
    def self.value_for(point, payload)
      a = point.address
      return image!(point, payload) if a["image"] == "mqtt"

      raw = a["value_template"].present? ? ::Mqtt::HaDiscovery.render(a["value_template"], payload.to_s).presence : extract(payload, a["json_path"].presence)
      return if raw.nil?

      raw = a["value_map"][raw.to_s] if a["value_map"].is_a?(Hash)
      return if raw.nil?
      return ::Points::Decode.invert(a, bool(point, raw)) if point.bool?
      return point.from_raw(raw.is_a?(String) ? Float(raw, exception: false) : raw) if point.numeric?

      point.data_type == "json" ? json(raw) : raw.to_s
    end

    def self.json(raw) = raw.is_a?(String) && raw.start_with?("{", "[") ? (JSON.parse(raw) rescue raw) : raw # rubocop:disable Style/RescueModifier

    # Quadro da câmera MQTT: vai para o cache de quadros do go2rtc; o valor é a hora em que chegou.
    def self.image!(point, payload)
      FileUtils.mkdir_p(Go2rtc::SNAPSHOT_DIR)
      Go2rtc::SNAPSHOT_DIR.join("#{point.id}.jpg").binwrite(payload.to_s.b)
      Time.current.iso8601
    end

    def self.extract(payload, path)
      return payload unless path

      data = JSON.parse(payload)
      path.split(".").reduce(data) { |d, k| d.is_a?(Hash) ? d[k] : nil }
    rescue JSON::ParserError
      nil
    end

    def self.bool(point, raw)
      a = point.address
      return true if raw.to_s == a.fetch("state_on", a.fetch("payload_on", true)).to_s
      return false if raw.to_s == a.fetch("state_off", a.fetch("payload_off", false)).to_s

      raw if [ true, false ].include?(raw)
    end
  end
end
