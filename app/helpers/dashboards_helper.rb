# Widgets de dashboard na web (o JSON resolvido por Dashboards::Resolver).
module DashboardsHelper
  DEFAULT_SPAN = { "mobile" => 12, "tablet" => 6, "desktop" => 4 }.freeze
  SECTION_SPAN = { "mobile" => 12, "tablet" => 12, "desktop" => 12 }.freeze
  AREA_ARTS = 6

  # Largura no grid de 12 colunas por tela, em variáveis CSS (.dw-w).
  def dw_span_style(span, default = DEFAULT_SPAN)
    s = default.merge(span || {})
    "--m: #{s['mobile']}; --t: #{s['tablet']}; --d: #{s['desktop']}"
  end

  # Visibilidade por tela (Lote 4, G18b): `visible_if.screen` → classes que escondem nas outras.
  def dw_screen_class(w)
    screens = w.dig("visible_if", "screen") or return ""
    (Dashboards::Schema::SCREENS - Array(screens)).map { |s| "dw-hide-#{s}" }.join(" ")
  end

  # Texto do widget Texto (Lote 4, G18a): escapa tudo e aplica um Markdown
  # mínimo: "# título" (até ###), "- item", **negrito**, *itálico*; linha em
  # branco separa parágrafos.
  # ponytail: subconjunto à mão; trocar por commonmarker se pedirem tabela/link.
  def dw_markdown(text)
    out = []
    block = nil # [:p | :ul, linhas]
    flush = lambda do
      if block
        out << (block[0] == :ul ? tag.ul(safe_join(block[1].map { |l| tag.li(dw_inline(l)) }), class: "list-disc pl-5") : tag.p(safe_join(block[1].map { |l| dw_inline(l) }, tag.br)))
      end
      block = nil
    end
    text.to_s.strip.each_line(chomp: true) do |line|
      kind, content = if line.strip.empty? then [ nil, nil ]
      elsif (m = line.match(/\A(\#{1,3}) (.+)/)) then [ :"h#{m[1].size}", m[2] ]
      elsif (m = line.match(/\A\s*[-*] (.+)/)) then [ :ul, m[1] ]
      else [ :p, line ]
      end
      flush.call if kind.nil? || kind.to_s.start_with?("h") || block&.first != kind
      next unless kind

      next out << tag.p(dw_inline(content), class: kind == :h1 ? "text-base font-bold text-ink" : "font-semibold text-ink") if kind.to_s.start_with?("h")

      (block ||= [ kind, [] ])[1] << content
    end
    flush.call
    safe_join(out)
  end

  def dw_inline(s)
    ERB::Util.html_escape(s).to_str.gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>').gsub(/(?<![*\w])\*(?!\s)(.+?)\*(?!\w)/, '<em>\1</em>').html_safe # rubocop:disable Rails/OutputSafety
  end

  def dw_light?(p) = p["capability"].in?(%w[onoff dimmer]) && "#{p['name']} #{p['device']}".match?(Dashboards::Generator::LIGHT)

  def dw_point_icon(p)
    return p["icon"] if p["icon"].present? && HelperTypes::ICONS.include?(p["icon"])
    return "light-bulb" if dw_light?(p)
    return "fan" if dw_fan?(p)
    return "lightning-bolt" if p["device_class"] == "power" || p["unit"] == "W"
    return "switch-horizontal" if p["capability"] == "onoff"

    PointsHelper::POINT_ICONS.fetch(p["capability"], "cube")
  end

  # Cor real da luz (o ponto `color` irmão, do JSON resolvido) para o brilho:
  # hs → #rrggbb; temperatura → do âmbar quente ao branco frio. nil = sem cor.
  def dw_glow(color)
    c = color && color["value"]
    return unless c.is_a?(Hash)
    return Points::Color.hex_of(c) if c["mode"] == "hs"
    return unless c["kelvin"].is_a?(Numeric)

    t = ((c["kelvin"] - 2000) / 4500.0).clamp(0, 1)
    format("#%02x%02x%02x", *[ 255, 166, 77 ].zip([ 214, 230, 255 ]).map { |a, b| (a + ((b - a) * t)).round })
  end

  # Ligado no desenho: verdadeiro/aberto, ou dimmer acima de zero.
  def dw_on?(p) = p["on"] || (p["capability"] == "dimmer" && p["value"].is_a?(Numeric) && p["value"].positive?)

  # Ventilador pelo nome (como a luz): o ícone gira; a velocidade vem do valor (0 a 100) se for dimmer.
  FAN = /ventila|\bfan\b|exaust/i
  def dw_fan?(p) = p["capability"].in?(%w[onoff dimmer enum]) && "#{p['name']} #{p['device']}".match?(FAN)
  def dw_spin_style(p)
    v = p["value"]
    pct = v.is_a?(Numeric) ? v.to_f.clamp(1, 100) : 60
    "--spin: #{(2.4 - (pct * 0.021)).round(2)}s"
  end

  COVER = /cortina|persiana|toldo|blackout/i
  def dw_cover?(p) = p["capability"].in?(%w[dimmer setpoint]) && "#{p['name']} #{p['device']}".match?(COVER)

  # Ícone do Ss::DeviceTileComponent: a arte do ponto (cortina e portão pela
  # posição, ventilador girando pela velocidade). O fundo aceso e a cor vêm do
  # `tone:` do tile (dw_tone), não daqui.
  def dw_device_icon(w, p)
    art = if w["icon"].present? then icon(w["icon"])
    elsif dw_cover?(p) then dw_cover_art(p["value"])
    elsif p["capability"] == "gate" then dw_gate_art(p["value"])
    else icon(dw_point_icon(p))
    end
    spin = dw_fan?(p) && dw_on?(p)
    tag.span(art, class: [ "dw-anim dw-ico-art", ("dw-spinning" if spin) ], style: (dw_spin_style(p) if spin)).to_s
  end

  # Cor do tile aceso: a cor real da luz, âmbar para luz sem cor, a cor do widget ou a marca.
  WIDGET_TONES = { "amber" => :heat, "green" => :success, "red" => :danger, "blue" => :info,
                   "ok" => :success, "warn" => :heat, "danger" => :danger, "info" => :info }.freeze
  # Tom do selo do card (style_if) → classe do .ss-badge da gem.
  FLAG_TONES = { "ok" => "ss-badge-success", "warn" => "ss-badge-warn", "danger" => "ss-badge-danger", "info" => "ss-badge-accent" }.freeze
  # Beleza (ideia 16): brilho real da luz (0 a 1) pelo ponto do brilho do tile (`level_id`):
  # o tile da gem (level:) acende mais fraco ou mais forte. nil = sem dimmer ou não é luz.
  def dw_level(w, points, p)
    return unless p && dw_light?(p)

    l = points[w.dig("data", "level_id")] or return
    v = l["value"]
    return unless v.is_a?(Numeric)

    min = (l["min"] || 0).to_f
    max = (l["max"] || 100).to_f
    max > min ? ((v.to_f - min) / (max - min)).clamp(0.0, 1.0).round(2) : nil
  end

  def dw_tone(w, p, glow: nil)
    return WIDGET_TONES[w["color"]] if w["color"].present?
    return glow || :heat if p && dw_light?(p)

    nil
  end

  # Parâmetros de um comando de widget (vão no form do componente da gem; o
  # form fica dentro do turbo-frame do widget e volta para ele).
  def dw_command_params(command, w:, dashboard:, live:, value: nil)
    params = { command: command, value: value }.compact
    params.merge!(dashboard_id: dashboard.id, widget_id: w["id"]) if live
    params
  end

  # Número sem ".0" para o Ss::RangeComponent (o sprintf do format e o JS mostram o valor cru).
  def dw_plain(v)
    return v unless v.is_a?(Numeric)

    (v % 1).zero? ? v.to_i : v.to_f
  end

  # Formato do Ss::RangeComponent pela unidade ("%s%%", "%s °C"; o % da unidade escapado).
  def dw_range_format(unit)
    return "%s" if unit.blank?

    unit == "%" ? "%s%%" : "%s #{unit.to_s.gsub('%', '%%')}"
  end

  # Texto da confirmação do ponto (risco ou `confirm`), para o `confirm:` da gem.
  def dw_confirm_text(p) = dw_confirm(p)[:turbo_confirm]

  # Estado do tile pelo ponto: sem sinal, sem permissão (comandaria, mas o papel não deixa) ou pronto.
  # Widget que ocupa a linha toda no celular: o tile deitado (ícone, nome e ação lado a lado) cabe; em meia
  # coluna, deitado o nome some entre o ícone e os botões, então ele fica em pé.
  def dw_full_row?(w) = (w.dig("span", "mobile") || 12).to_i >= 12
  # Um terço da linha ou menos: o ⋯ de detalhes não cabe ao lado do botão (os detalhes ficam no nome do ponto).
  def dw_narrow?(w) = (w.dig("span", "mobile") || 12).to_i <= 4

  # "5 min", "3 h", "2 d": cabe no tile estreito (o time_ago_in_words diz "aproximadamente 1 hora").
  def dw_short_ago(time)
    secs = (Time.current - time).to_i.clamp(0, nil)
    return t("dashboards.w.ago_min", n: [ secs / 60, 1 ].max) if secs < 3600
    return t("dashboards.w.ago_h", n: secs / 3600) if secs < 86_400

    t("dashboards.w.ago_d", n: secs / 86_400)
  end

  # Comando a caminho (Points::Inflight): anel girando e "Enviando…"; falhou há pouco: erro.
  def dw_tile_status(p, off_line)
    return :unavailable if off_line
    return :locked if p["locked"]
    return :pending if p["pending"]
    return :error if p["failed"]

    :ready
  end

  # Janela com a cortina na posição (0 = fechada, 100 = aberta).
  def dw_cover_art(value)
    open = value.is_a?(Numeric) ? value.to_f.clamp(0, 100) / 100 : 0.5
    tag.svg(safe_join([ tag.rect(x: 3, y: 3, width: 18, height: 18, rx: 2.5, fill: "none", stroke: "currentColor", "stroke-width": 2),
                        tag.rect(x: 5, y: 5, width: 14, height: 14, rx: 1, class: "dw-cover-blind", fill: "currentColor", style: "--c: #{(1 - open).round(2)}"),
                        tag.path(d: "M12 5v14", stroke: "currentColor", "stroke-width": 1, opacity: ".35") ]),
            viewBox: "0 0 24 24", class: "size-5", "aria-hidden": true)
  end

  # Portão: as grades correm para o lado quando abre; "abrindo" anima.
  def dw_gate_art(value)
    bars = safe_join((0..3).map { |i| tag.path(d: "M#{6 + (i * 3.5)} 7v12", stroke: "currentColor", "stroke-width": 1.8, "stroke-linecap": "round") })
    tag.svg(safe_join([ tag.path(d: "M3 4v16M21 4v16", stroke: "currentColor", "stroke-width": 2.2, "stroke-linecap": "round"),
                        tag.g(safe_join([ bars, tag.path(d: "M5 9h12M5 16h12", stroke: "currentColor", "stroke-width": 1.4) ]), class: "dw-gate-bars dw-gate-#{value.presence || 'unknown'}") ]),
            viewBox: "0 0 24 24", class: "size-5", "aria-hidden": true)
  end

  # Condição do clima (Weather::CONDITIONS, as do HA) → a do Ss::WeatherCardComponent.
  WEATHER_CONDITIONS = { "sunny" => :clear, "clear-night" => :clear_night, "partlycloudy" => :partly_cloudy, "cloudy" => :cloudy,
                         "fog" => :fog, "rainy" => :rain, "pouring" => :rain, "snowy-rainy" => :rain, "hail" => :rain,
                         "lightning-rainy" => :storm, "snowy" => :snow, "windy" => :wind }.freeze
  def dw_weather_condition(c) = WEATHER_CONDITIONS.fetch(c.to_s, :cloudy)

  # Capa da mídia só por link seguro (https:// ou do próprio servidor).
  def dw_media_image(m) = m["image"].to_s.match?(%r{\A(https://|/)[^"'()\s<>]+\z}) ? m["image"] : nil

  # Tema resolvido (Dashboards::Themes.resolve) → classe e style do <body>:
  # variáveis de cor, papel de parede (link já validado no Schema), desfoque e vidro.
  def dw_theme_attrs(th)
    t = th["theme"]
    image = th["image"].to_s.match?(Dashboards::Themes::IMAGE) ? th["image"] : nil
    wall = Dashboards::Themes.wall_css(th["wall"]) # beleza (ideia 15): fundo da faixa do dia (cor/degradê)
    dim = th["dim"].to_i.clamp(0, 80)
    style = [ t.css, ("--wall: #{wall}" if wall), ("--wall-img: url('#{image}')" if image), "--wall-blur: #{th['blur'].to_i}px",
              ("--wall-dim: #{dim}%" if dim.positive?) ].compact.join("; ")
    { "class" => [ "dw-themed", "dw-theme-#{t.key}", ("dw-glass" if th["glass"]), ("dw-has-wall" if image || t.wallpaper || wall),
                   ("dw-dim" if dim.positive?), ("dw-night" if th["is_night"]) ].compact.join(" "), "style" => style }
  end

  # Amostra de tema (.ss-swatch da gem): as cores do tema nos círculos e o papel de parede atrás deles.
  def dw_swatch_style(th)
    [ th.css, "--p1: #{th.accent}", "--p2: #{th.accent2}", "--p3: var(--accent-soft)", ("--ss-swatch-wall: #{th.wallpaper}" if th.wallpaper.present?) ].compact.join("; ")
  end

  # Linha de lista e tile: título e contexto pela regra de Point#display_names (resolver).
  def dw_row_names(p) = [ p["title"] || p["name"], p.key?("title") ? p["context"] : p["device"] ]
  def dw_label(w, p) = w.dig("data", "title").presence || w["label"].presence || p["name"]

  # Botão de comando de um widget: passa por PointsController#command (papel,
  # risco e Points::Command) e volta para o próprio quadro do widget.
  def dw_command_button(p, command, w:, dashboard:, live:, value: nil, **opts, &)
    params = { command: command, value: value }.compact
    params.merge!(dashboard_id: dashboard.id, widget_id: w["id"]) if live
    form_data = dw_confirm(p).merge(turbo_frame: live ? nil : "_top").compact
    button_to(command_point_path(p["id"]), params: params, form: { data: form_data, class: opts.delete(:form_class) }, **opts, &)
  end

  # Formulário de valor (slider, seleção) que se envia sozinho ao mudar.
  def dw_command_form(p, command, w:, dashboard:, live:, data: {}, css: "mt-3", &)
    form_with url: command_point_path(p["id"]), data: dw_confirm(p).merge(turbo_frame: live ? nil : "_top", **data).compact, class: css do |f|
      safe_join([ hidden_field_tag(:command, command, id: nil),
                  (hidden_field_tag(:dashboard_id, dashboard.id, id: nil) if live),
                  (hidden_field_tag(:widget_id, w["id"], id: nil) if live), capture(f, &) ].compact)
    end
  end

  def dw_confirm(p)
    return {} if p["confirm"].blank? && p["risk"] == "normal"

    { turbo_confirm: p["confirm"].presence || t("points.confirm", name: p["name"]), turbo_confirm_title: Point::RISKS.fetch(p["risk"], t("shared.confirm.ok")).to_s }
  end

  def dw_number(v, unit = nil)
    return "—" if v.nil?

    [ number_with_precision(v, precision: 1, strip_insignificant_zeros: true, delimiter: "."), unit ].compact.join(" ")
  end

  # Fundo do cartão de área: a foto da área ou um dos gradientes da casa (fixo por área).
  def dw_area_art(area) = "dw-art-#{area['id'].to_s.bytes.sum % AREA_ARTS}"

  # Tom do bloco do cartão de área (variant: do Ss::MosaicTileComponent, 0 a 4): a mesma conta do app
  # (soma dos códigos do id), para a área ter a mesma cor no web e no app.
  def dw_area_variant(area) = area["id"].to_s.bytes.sum % 5

  # ondaB2 (B9): gestos do widget (Dashboards::Actions) → [atributos do
  # controlador dw-gesture, elementos escondidos que ele dispara]. Comando vira
  # formulário (papel, risco e confirmação valem como num botão); o resto, link.
  def dw_gestures(w, points, dashboard:, live:)
    gestures = w["gestures"].presence or return [ {}, "".html_safe ]

    items = gestures.filter_map do |g, a|
      data = { gesture: g, confirm: a["confirm"] }.compact
      case a["action"]
      when "toggle", "command"
        p = points[a["point_id"]]
        next unless p && p["can_command"] && (a["action"] == "toggle" || a["can_command"])

        params = { command: a["command"], value: a["value"] }.compact
        params.merge!(dashboard_id: dashboard.id, widget_id: w["id"]) if live
        confirm = a["confirm"] ? { turbo_confirm: a["confirm"] } : dw_confirm(p)
        button_to("", command_point_path(p["id"]), params: params, hidden: true, tabindex: -1,
                                                   form: { hidden: true, data: confirm.merge(gesture: g, turbo_frame: live ? nil : "_top").compact })
      when "more_info" then a["point_id"] && link_to("", point_path(a["point_id"]), hidden: true, tabindex: -1, data: data.merge(turbo_frame: "_top"))
      when "navigate"
        path = a["path"].to_s.start_with?("/") ? a["path"] : dashboard_path(dashboard, view: a["path"])
        link_to("", path, hidden: true, tabindex: -1, data: data.merge(turbo_frame: "_top"))
      when "url" then link_to("", a["url"], hidden: true, tabindex: -1, target: "_blank", rel: "noopener noreferrer", data: data)
      else tag.span(hidden: true, data: data.merge(kind: a["action"]))
      end
    end
    [ { controller: "dw-gesture", dw_gesture_kinds_value: gestures.keys.join(" ") }, safe_join(items) ]
  end

  # Controle aprendido (widget remote) → teclas do Ss::DPadComponent pelo nome do botão
  # ("Cima", "up", "OK", "Vol +"...). Só vira cruz com as 5 teclas da cruz aprendidas; a linha
  # voltar/início/menu e as gangorras só com todas as delas. O resto vai em extra_buttons.
  # nil = sem cruz (a tela mostra os botões soltos).
  REMOTE_KEYS = {
    up: %w[up cima paracima arriba], down: %w[down baixo parabaixo abajo], left: %w[left esquerda izquierda],
    right: %w[right direita derecha], ok: %w[ok select enter confirmar], back: %w[back voltar return volver atras],
    home: %w[home inicio], menu: %w[menu], volume_up: %w[volup volumeup volume+ vol+ aumentarvolume subirvolume],
    volume_down: %w[voldown volumedown volume- vol- baixarvolume diminuirvolume bajarvolume], mute: %w[mute mudo semsom silencio],
    channel_up: %w[chup channelup canal+ ch+ proximocanal], channel_down: %w[chdown channeldown canal- ch- canalanterior]
  }.freeze
  REMOTE_GROUPS = { cross: %i[up down left right ok], nav: %i[back home menu], volume: %i[volume_up volume_down], channel: %i[channel_up channel_down] }.freeze

  def dw_remote_pad(buttons)
    norm = ->(b) { I18n.transliterate(b.to_s).downcase.gsub(/[^a-z0-9+-]/, "") }
    keys = {}
    Array(buttons).each do |b|
      key = REMOTE_KEYS.find { |_, names| names.include?(norm.(b)) }&.first
      keys[key] ||= b if key
    end
    return unless REMOTE_GROUPS[:cross].all? { keys.key?(_1) }

    use = ->(g) { REMOTE_GROUPS[g].all? { keys.key?(_1) } }
    used = keys.slice(*REMOTE_GROUPS[:cross], *(REMOTE_GROUPS[:nav] if use.(:nav)), *(REMOTE_GROUPS[:volume] if use.(:volume)),
                      *(REMOTE_GROUPS[:channel] if use.(:channel)), *(:mute if keys.key?(:mute)))
    { keys: used, nav_row: use.(:nav), volume: use.(:volume), channel: use.(:channel), mute: keys.key?(:mute),
      extra_buttons: (Array(buttons) - used.values).map { |b| { name: b, label: b } } }
  end

  # Recurso do tile: o partial do plugin (ou o do kind).
  def dw_feature_partial(f) = Dashboards::TileFeatures[f["type"]]&.partial || "web/dashboards/features/#{f['kind']}"

  def dw_view_path(dashboard, view, home:)
    slug = view["path"].presence || view["id"]
    home ? root_path(local: dashboard.site_id, view: slug) : dashboard_path(dashboard, view: slug)
  end
end
