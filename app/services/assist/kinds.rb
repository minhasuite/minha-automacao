module Assist
  # Tipos de aparelho falados (voz-offline): "as luzes da sala", "a janela do
  # quarto", "os ventiladores" sem precisar de ponto com esse nome. Dado, não
  # código por marca: cada tipo tem as palavras nos três idiomas (já sem
  # acento e no singular, como `Assist.stem` deixa) e o que um ponto precisa
  # para ser dele — capacidade, `device_class`, rótulo ou parte do nome do
  # ponto/aparelho. Tipo novo = uma entrada em DEFAULT. O local pode trocar
  # ou somar tipos em `sites.settings["assist_kinds"]` (mesmo formato).
  module Kinds
    DEFAULT = {
      "light" => { "words" => %w[luz lampada iluminacao abajur spot light lamp lighting luce lampara],
                   "capabilities" => %w[dimmer color], "device_classes" => %w[light], "tags" => %w[iluminacao luz],
                   "names" => %w[luz luzes lampada ilumina led abajur spot pendente arandela plafon light lamp],
                   "name_capabilities" => %w[onoff dimmer] },
      "fan" => { "words" => %w[ventilador fan], "device_classes" => %w[fan],
                 "names" => %w[ventilador fan], "name_capabilities" => %w[onoff dimmer setpoint enum] },
      "outlet" => { "words" => %w[tomada plug outlet socket enchufe], "device_classes" => %w[outlet plug],
                    "names" => %w[tomada plug outlet enchufe], "name_capabilities" => %w[onoff] },
      "window" => { "words" => %w[janela window ventana], "device_classes" => %w[window] },
      "door" => { "words" => %w[porta door puerta], "device_classes" => %w[door garage_door opening] },
      "curtain" => { "words" => %w[cortina persiana blind curtain shade shutter], "device_classes" => %w[curtain blind shade shutter awning] },
      "tv" => { "words" => %w[tv televisao televisor television], "capabilities" => %w[media remote], "names" => %w[tv televis] }
    }.freeze
    LINKS = %w[da do de das dos na no nas nos em in on of the del la el en los las].freeze

    # Ajustes do aparelho que têm liga/desliga mas não são o aparelho (o LED do
    # interruptor, a trava do botão, a luz da câmera): nunca contam como tipo
    # ("as luzes") nem entram no "desligue o escritório". Pelo nome dito à
    # pessoa (já normalizado); o local soma em `sites.settings["assist_settings"]`.
    # Chamar pelo nome continua valendo ("desligue a luz indicadora da câmera").
    SETTINGS = [
      "luz de fundo", "luz indicadora", "indicador", "led indicador", "trava infantil", "bloqueio infantil",
      "modo privacidade", "hora na imagem", "imagem invertida", "deteccao de", "agenda da deteccao",
      "gravar ao detectar", "gravacao", "seguir movimento", "so pessoas", "contorno de objetos",
      "sirene automatica", "nao perturbe", "ultimo chamado", "power on behavior", "comportamento ao ligar",
      "backlight", "indicator", "child lock", "do not disturb", "luz de fondo", "bloqueo infantil"
    ].freeze

    module_function

    def all(site) = DEFAULT.merge(site.settings.to_h["assist_kinds"].to_h.select { |_k, v| v.is_a?(Hash) })

    # "luzes da sala" → ["light", "sala"]; "janelas" → ["window", ""]; não é tipo → nil.
    def split(site, want)
      first, *rest = want.split
      return unless first

      stem = Assist.stem(first)
      kind = all(site).find { |_k, v| Array(v["words"]).include?(stem) || Array(v["words"]).include?(first) }&.first or return
      rest.shift while rest.first.in?(LINKS)
      [ kind, rest.join(" ") ]
    end

    def setting?(site, point)
      text = Assist.normalize(point.name)
      (SETTINGS + Array(site.settings.to_h["assist_settings"]).map { |n| Assist.normalize(n) }).any? { |n| text.match?(/\b#{Regexp.escape(n)}\b/) }
    end

    def match?(site, kind, point)
      rule = all(site)[kind] or return false
      return false if setting?(site, point)
      return true if point.capability.in?(Array(rule["capabilities"]))
      return true if point.device_class.present? && point.device_class.in?(Array(rule["device_classes"]))
      return true if (Array(rule["tags"]) & point.label_names).any?

      names = Array(rule["names"])
      return false if names.empty? || !point.capability.in?(Array(rule["name_capabilities"]).presence || Point::CAPABILITIES.keys)

      text = Assist.normalize([ point.name, point.device&.name ].compact.join(" "))
      names.any? { |n| text.match?(/\b#{Regexp.escape(n)}/) }
    end
  end
end
