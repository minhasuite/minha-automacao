# Câmeras TP-Link Tapo (TapoPlugin). O vídeo e o movimento são os de
# qualquer câmera ONVIF (Onvif, go2rtc, Onvif::Listener; a Tapo fala ONVIF na
# porta 2020 com a "conta da câmera" criada no app). Aqui ficam só os dados
# por modelo (config/device_maps/tapo.yml) e o controle pela API local
# (Tapo::Client): privacidade, LED, detecção de movimento e sirene.
#
# O controle é opcional: só com a senha da nuvem, a caixa "Controlar pela
# API local" marcada na integração e o FeatureFlag `tapo_control` ligado
# (interruptor geral para desligar se um firmware novo quebrar o login).
# Ponto de controle = onoff com `address.tapo` = tipo do mapa (`controls`).
module Tapo
  class Error < Integrations::Error; end

  MAP = YAML.load_file(Rails.root.join("config/device_maps/tapo.yml")).freeze
  FLAG = "tapo_control".freeze

  module_function

  # Modelo do ONVIF ("C200", "Tapo C520WS") → recursos da família (prefixo mais longo).
  def preset(model)
    m = model.to_s.upcase.sub(/\ATAPO[\s_-]*/, "").delete(" ")
    family = MAP["families"].flat_map { |f| f["models"].map { |p| [ p.to_s.upcase, f ] } }
                            .select { |p, _| m.start_with?(p) }.max_by { |p, _| p.length }&.last
    MAP["default"].merge(family.to_h.except("models"))
  end

  def enabled? = FeatureFlag.on?(FLAG)

  # Pontos de controle que a família tem (sirene só com sirene).
  def control_points(features)
    MAP["controls"].filter_map do |key, c|
      next if c["needs"] && !features[c["needs"]]

      { "name" => I18n.t("tapo.points.#{key}"), "capability" => "onoff", "writable" => true, "history" => "on_change",
        "risk" => c["risk"] || "normal", "address" => { "tapo" => key } }
    end
  end

  def client(host, password) = Client.new(host: host, password: password)

  # Lê os controles que têm leitura → {tipo => true/false}. Um que falha não derruba os outros.
  def read(client, keys)
    keys.each_with_object({}) do |key, out|
      get = MAP.dig("controls", key, "get") or next
      out[key] = client.call(get["method"], get["params"]).dig(*get["path"]).to_s == "on"
    rescue Tapo::Error => e
      raise if e.is_a?(Integrations::AuthError)

      Rails.logger.warn("[tapo] #{key}: #{e.message}")
    end
  end

  # Liga/desliga um controle na câmera.
  def write(client, key, on)
    set = MAP.dig("controls", key, "set") or raise Error, "Tapo: #{key} sem comando."
    vars = { "$state" => on ? "on" : "off", "$action" => on ? "start" : "stop" }
    return client.raw(fill(set["raw"], vars)) if set["raw"]

    client.call(set["method"], fill(set["params"], vars))
  end

  def fill(tree, vars)
    case tree
    when Hash then tree.transform_values { |v| fill(v, vars) }
    when Array then tree.map { |v| fill(v, vars) }
    else vars.fetch(tree, tree)
    end
  end
end
