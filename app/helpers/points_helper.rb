# Locais, áreas e pontos na tela.
module PointsHelper
  SITE_ICONS = { "home" => "home", "store" => "shopping-bag", "plant" => "office-building" }.freeze
  POINT_ICONS = { "onoff" => "light-bulb", "dimmer" => "sun", "color" => "sparkles", "gate" => "switch-horizontal",
                  "contact" => "view-boards", "motion" => "eye", "tamper" => "exclamation-circle", "problem" => "exclamation-circle",
                  "measure" => "chart-bar", "enum" => "view-list", "setpoint" => "calculator", "command" => "lightning-bolt",
                  "text" => "document-text", "vacuum" => "vacuum", "speaker" => "speakerphone", "stream" => "video-camera",
                  "climate" => "sun", "event" => "bell", "counter" => "plus", "timer" => "clock", "datetime" => "calendar",
                  "script" => "play", "calendar" => "calendar", "weather" => "sun", "media" => "desktop-computer",
                  "remote" => "status-online", "detection" => "user-circle", "todo" => "clipboard-list" }.freeze
  # Pacote 1: situação da mídia (`value.state`, nomes do HA).
  MEDIA_TEXT = LocalizedLabel.for("labels.media", %w[off on idle playing paused buffering standby])
  BOOL_TEXT = %w[onoff contact motion tamper problem].to_h { |c| [ c, LocalizedLabel.for("labels.bool.#{c}", %w[on off]).values ] }.freeze
  GATE_TEXT = LocalizedLabel.for("labels.states.gate", %w[open closed opening unknown])
  # Estados de texto por capacidade (portão, robô, Echo).
  STATE_TEXT = {
    "gate" => GATE_TEXT,
    "vacuum" => LocalizedLabel.for("labels.states.vacuum", %w[docked cleaning returning paused idle error]),
    "speaker" => LocalizedLabel.for("labels.states.speaker", %w[online offline]),
    "timer" => LocalizedLabel.for("labels.states.timer", %w[idle active paused finished]),
    "weather" => Weather::CONDITIONS.transform_values(&:first)
  }.freeze
  # Botões de ação (Points::Command.actions_for): comando → [ícone, rótulo].
  ACTION_BUTTONS = { "increment" => "plus", "decrement" => "minus", "reset" => "refresh", "start" => "play", "pause" => "pause", "cancel" => "x",
                     "finish" => "check" }.to_h { |c, ico| [ c, [ ico, LocalizedLabel.new("labels.actions.#{c}") ] ] }.freeze

  def site_icon(site) = SITE_ICONS.fetch(site.kind, "home")
  def point_icon(point) = point.icon.presence_in(HelperTypes::ICONS) || POINT_ICONS.fetch(point.capability, "cube")
  def point_on?(point) = point.value == true || point.value == "open"
  def count_label(n, one, many) = "#{n} #{n == 1 ? one : many}"

  # 5400 → "1 h 30 min"; menos de um minuto → "45 s".
  def duration_text(seconds)
    h, rest = seconds.to_i.divmod(3600)
    m, s = rest.divmod(60)
    return I18n.t("shared.duration.s", n: s) if h.zero? && m.zero?

    [ (I18n.t("shared.duration.h", n: h) if h.positive?), (I18n.t("shared.duration.min", n: m) if m.positive?) ].compact.join(" ")
  end

  # "há 7 min", "há 1 h 5 min"; mais de um dia = data curta.
  def ago_text(time)
    secs = (Time.current - time).to_i
    return I18n.t("shared.ago.now") if secs < 60
    return l(time, format: :short) if secs >= 86_400

    I18n.t("shared.ago.text", time: duration_text(secs / 60 * 60))
  end

  # Formulário do tipo de helper: a partial própria (`web/site_helpers/forms/_<key>`) ou, quando o
  # plugin descreve os campos (`form_spec`), a genérica.
  def helper_form_partial(plugin)
    own = "web/site_helpers/forms/#{plugin.key}"
    lookup_context.exists?(own, [], true) || plugin.form_spec.empty? ? own : "web/site_helpers/forms/generic"
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
    return I18n.t("points.poll.none") if seconds.to_i <= 0

    I18n.t("points.poll.every", time: duration_text(seconds))
  end

  # Data/hora em ISO (o servidor, o robô, o helper Data e hora) → Time/Date para mostrar; nil = texto qualquer.
  def datetime_of(value)
    s = value.to_s
    return Date.iso8601(s) if s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    return Time.zone.parse(s) if s.match?(/\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/)

    nil
  rescue ArgumentError
    nil
  end

  # "Redefinir estado" (Points::Reset): opções do estado real; nil = número digitado.
  def reset_choices(point)
    if point.bool?
      on, off = BOOL_TEXT.fetch(point.capability, [ I18n.t("points.turn_on"), I18n.t("points.turn_off") ])
      [ [ on.to_s, "true" ], [ off.to_s, "false" ] ]
    elsif point.option_values.any?
      point.option_values.map { |o| [ STATE_TEXT.dig(point.capability, o)&.to_s || o, o ] }
    end
  end

  def point_value_text(point)
    v = point.value
    if (text = point.helper_type&.value_text(point))
      text
    elsif point.capability == "command"
      point.reported_at ? I18n.t("points.value.fired", at: l(point.reported_at, format: :short)) : I18n.t("points.value.ready")
    elsif point.capability == "calendar"
      calendar_text(v)
    elsif point.capability == "detection"
      Detections.text(v)
    elsif point.capability == "climate" && v.is_a?(Hash)
      climate_text(v) # integ2: resumo do ar-condicionado
    elsif v.nil?
      I18n.t("points.value.none")
    elsif point.capability == "datetime" && (when_at = datetime_of(v))
      when_at.is_a?(Date) && !when_at.is_a?(DateTime) ? l(when_at, format: :long) : l(when_at, format: :short)
    elsif point.capability == "color" && v.is_a?(Hash)
      v["mode"] == "temp" ? I18n.t("points.value.white", k: v["kelvin"]) : Points::Color.hex_of(v).upcase # Lote 8
    elsif BOOL_TEXT.key?(point.capability)
      BOOL_TEXT[point.capability][v ? 0 : 1].to_s
    elsif STATE_TEXT.key?(point.capability)
      STATE_TEXT[point.capability].fetch(v.to_s, v.to_s).to_s
    elsif v.is_a?(Numeric)
      v, unit = Units.for_display(point, v) # ondaA1 (A4): unidade do local ou a escolhida para o ponto
      [ number_with_precision(v, precision: 2, strip_insignificant_zeros: true), unit ].compact.join(" ")
    elsif v.is_a?(Hash) && v.key?("state")
      [ MEDIA_TEXT.fetch(v["state"].to_s, v["state"].to_s.humanize).to_s, v["title"].presence ].compact.join(" · ")
    elsif v.is_a?(Hash) && v.key?("buttons")
      I18n.t("points.value.buttons", count: v["buttons"].to_i)
    elsif v.is_a?(Hash) || v.is_a?(Array)
      v.to_json.truncate(40)
    else
      v.to_s
    end
  end

  # Ícone do aparelho pelo que os pontos dele fazem (o dispositivo não tem tipo próprio).
  DEVICE_ICON_ORDER = %w[stream vacuum media remote gate climate speaker dimmer onoff contact motion measure enum].freeze
  def device_icon(device)
    points = device.points.to_a
    cap = DEVICE_ICON_ORDER.find { |c| points.any? { |p| p.capability == c } } or return "cube"
    return "light-bulb" if cap.in?(%w[onoff dimmer]) && "#{device.name} #{points.map(&:name).join(' ')}".match?(Dashboards::Generator::LIGHT)
    return "switch-horizontal" if cap == "onoff"

    POINT_ICONS.fetch(cap, "cube")
  end

  # Situação do aparelho para a lista e o diagnóstico: [rótulo, tom, explicação].
  # "Conectado" sem nenhum contato ainda vira "Sem contato" (ex.: não informa o estado sozinho).
  DEVICE_TONES = { "online" => "success", "offline" => "danger", "error" => "danger", "new" => "accent", "removed" => "warn" }.freeze
  def device_situation(device)
    s = device.situation
    note = { "offline" => I18n.t("points.situation.offline"), "error" => device.last_error.presence || I18n.t("points.situation.error") }[s]
    # Só para driver que o servidor lê (os outros não marcam o contato e estariam bem).
    if s == "online" && device.last_seen_at.nil? && Polling.supported?(device)
      reads = device.listen || device.poll_s.to_i.positive?
      return [ I18n.t("points.situation.no_contact"), "muted", reads ? I18n.t("points.situation.waiting") : I18n.t("points.situation.silent") ]
    end
    [ Device::SITUATIONS[s].to_s, DEVICE_TONES.fetch(s, "muted"), note ]
  end

  # Por que o ponto está sem sinal ou sem valor (web e app). nil = nada a explicar.
  def point_status_note(point)
    if point.quality.in?(%w[unavailable error])
      since = point.changed_at || point.reported_at
      return I18n.t("points.status.no_signal", ago: (" (#{ago_text(since)})" if since))
    end
    return unless point.value.nil? && point.helper.blank? && !point.capability.in?(%w[command script calendar stream])

    dev = point.device
    reads = dev.nil? || dev.virtual? || dev.listen || (Polling.supported?(dev) && dev.poll_s.to_i.positive?)
    reads ? I18n.t("points.status.waiting") : I18n.t("points.status.silent")
  end

  # Agenda (F9): "Agora: Reunião" ou "Reunião · sex 14:00" (dia inteiro: só a data).
  def calendar_text(v)
    return I18n.t("points.calendar.nothing") unless v.is_a?(Hash) && v["start"]
    return I18n.t("points.calendar.now", summary: v["summary"]) if v["now"]

    at = Time.zone.parse(v["start"])
    when_text = if at.to_date == Date.current then I18n.t("points.calendar.today")
    elsif at.to_date == Date.current + 1 then I18n.t("points.calendar.tomorrow")
    else l(at, format: "%a %d/%m")
    end
    "#{v['summary']} · #{when_text}#{l(at, format: ' %H:%M') unless v['all_day']}"
  end

  # Valor do ponto para um <input> (data/hora no formato do campo).
  def point_input_type(point)
    return "number" if point.numeric?
    return { "date" => "date", "time" => "time" }.fetch(point.address["mode"], "datetime-local") if point.capability == "datetime"

    point.address["password"] ? "password" : "text"
  end

  # Um valor qualquer no texto do ponto (regras: "quando ficar Aberto").
  # integ2: {power, mode, target, current} → "Ligado · Refrigerar · 23 °C · ambiente 25,5 °C".
  def climate_text(v)
    return "Desligado" if v["power"] == false

    c = ->(x) { x.is_a?(Numeric) ? "#{number_with_precision(x, precision: 1, strip_insignificant_zeros: true)} °C" : nil }
    [ ("Ligado" if v["power"]), v["mode"], c.call(v["target"]), (a = c.call(v["current"])) && "ambiente #{a}" ].compact.join(" · ")
  end

  def point_value_label(point, value) = point_value_text(point.dup.tap { |p| p.value = value })

  # Confirmação antes de acionar ponto sensível, crítico ou com texto próprio.
  def point_confirm_data(point)
    return {} if point.confirm.blank? && point.risk == "normal"

    { turbo_confirm: point.confirm.presence || I18n.t("points.confirm", name: point.name), turbo_confirm_title: point.risk_label.to_s }
  end
end
