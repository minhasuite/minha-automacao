# Locais, áreas e pontos na tela.
module PointsHelper
  SITE_ICONS = { "home" => "home", "store" => "shopping-bag", "plant" => "office-building" }.freeze
  POINT_ICONS = { "onoff" => "light-bulb", "dimmer" => "sun", "color" => "sparkles", "gate" => "switch-horizontal",
                  "contact" => "view-boards", "motion" => "eye", "tamper" => "exclamation-circle", "problem" => "exclamation-circle",
                  "measure" => "chart-bar", "enum" => "view-list", "setpoint" => "calculator", "command" => "lightning-bolt",
                  "text" => "document-text", "vacuum" => "vacuum", "speaker" => "speakerphone", "stream" => "video-camera",
                  "climate" => "sun", "event" => "bell", "counter" => "plus", "timer" => "clock", "datetime" => "calendar" }.freeze
  BOOL_TEXT = { "onoff" => %w[Ligado Desligado], "contact" => %w[Aberto Fechado], "motion" => %w[Movimento Parado],
                "tamper" => %w[Violado Normal], "problem" => %w[Problema Normal] }.freeze
  GATE_TEXT = { "open" => "Aberto", "closed" => "Fechado", "opening" => "Abrindo", "unknown" => "Desconhecido" }.freeze
  # Estados de texto por capacidade (portão, robô, Echo).
  STATE_TEXT = {
    "gate" => GATE_TEXT,
    "vacuum" => { "docked" => "Na base", "cleaning" => "Limpando", "returning" => "Voltando para a base", "paused" => "Pausado",
                  "idle" => "Parado", "error" => "Com erro" },
    "speaker" => { "online" => "Pronta", "offline" => "Fora do ar" },
    "timer" => { "idle" => "Parado", "active" => "Contando", "paused" => "Pausado", "finished" => "Terminou" }
  }.freeze
  # Botões de ação (Points::Command.actions_for): comando → [ícone, rótulo].
  ACTION_BUTTONS = { "increment" => %w[plus Mais], "decrement" => %w[minus Menos], "reset" => %w[refresh Zerar],
                     "start" => %w[play Iniciar], "pause" => %w[pause Pausar], "cancel" => %w[x Cancelar], "finish" => %w[check Terminar] }.freeze

  TONE_CLASSES = { "success" => "text-success", "danger" => "text-danger", "warn" => "text-warn", "muted" => "text-muted" }.freeze

  def site_icon(site) = SITE_ICONS.fetch(site.kind, "home")
  def point_icon(point) = point.icon.presence_in(HelperTypes::ICONS) || POINT_ICONS.fetch(point.capability, "cube")
  def point_on?(point) = point.value == true || point.value == "open"
  def count_label(n, one, many) = "#{n} #{n == 1 ? one : many}"

  # 5400 → "1 h 30 min"; menos de um minuto → "45 s".
  def duration_text(seconds)
    h, rest = seconds.to_i.divmod(3600)
    m, s = rest.divmod(60)
    return "#{s} s" if h.zero? && m.zero?

    [ ("#{h} h" if h.positive?), ("#{m} min" if m.positive?) ].compact.join(" ")
  end

  # "há 7 min", "há 1 h 5 min"; mais de um dia = data curta.
  def ago_text(time)
    secs = (Time.current - time).to_i
    return "agora" if secs < 60
    return l(time, format: :short) if secs >= 86_400

    "há #{duration_text(secs / 60 * 60)}"
  end

  # Segundos → "1h30m" (campo de duração dos helpers).
  def helper_duration(seconds)
    return if seconds.nil?

    h, rest = seconds.to_i.divmod(3600)
    m, s = rest.divmod(60)
    [ ("#{h}h" if h.positive?), ("#{m}m" if m.positive?), ("#{s}s" if s.positive?) ].join.presence || "0s"
  end

  # Intervalo da leitura periódica (segundos) em texto.
  def poll_label(seconds)
    return "sem leitura periódica" if seconds.to_i <= 0

    "leitura a cada #{duration_text(seconds)}"
  end

  def point_value_text(point)
    v = point.value
    if (text = point.helper_type&.value_text(point))
      text
    elsif point.capability == "command"
      point.reported_at ? "Acionado #{l(point.reported_at, format: :short)}" : "Pronto"
    elsif v.nil?
      "Sem valor"
    elsif BOOL_TEXT.key?(point.capability)
      BOOL_TEXT[point.capability][v ? 0 : 1]
    elsif STATE_TEXT.key?(point.capability)
      STATE_TEXT[point.capability].fetch(v.to_s, v.to_s)
    elsif v.is_a?(Numeric)
      [ number_with_precision(v, precision: 2, strip_insignificant_zeros: true), point.unit ].compact.join(" ")
    elsif v.is_a?(Hash) || v.is_a?(Array)
      v.to_json.truncate(40)
    else
      v.to_s
    end
  end

  # Valor do ponto para um <input> (data/hora no formato do campo).
  def point_input_type(point)
    return "number" if point.numeric?
    return { "date" => "date", "time" => "time" }.fetch(point.address["mode"], "datetime-local") if point.capability == "datetime"

    point.address["password"] ? "password" : "text"
  end

  # Um valor qualquer no texto do ponto (regras: "quando ficar Aberto").
  def point_value_label(point, value) = point_value_text(point.dup.tap { |p| p.value = value })

  # Confirmação antes de acionar ponto sensível, crítico ou com texto próprio.
  def point_confirm_data(point)
    return {} if point.confirm.blank? && point.risk == "normal"

    { turbo_confirm: point.confirm.presence || "Acionar #{point.name}?", turbo_confirm_title: point.risk_label }
  end
end
