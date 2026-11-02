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

  # Ícone do tile animado pelo estado real (uiweb, só CSS; para com
  # prefers-reduced-motion): luz brilha na cor real e no nível do dimmer,
  # ventilador gira pela velocidade, cortina e portão abrem pela posição.
  def dw_tile_ico(w, p, glow: nil)
    on = dw_on?(p)
    css = %w[dw-ico dw-anim]
    style = []
    if dw_light?(p) && on
      css << "dw-glow"
      style << "--glow: #{glow}" if glow
      style << "--lvl: #{(p['value'].to_f / 100).clamp(0.3, 1).round(2)}" if p["capability"] == "dimmer"
    end
    if dw_fan?(p) && on
      css << "dw-spinning"
      style << dw_spin_style(p)
    end
    art = if w["icon"].present? then icon(w["icon"])
    elsif dw_cover?(p) then dw_cover_art(p["value"])
    elsif p["capability"] == "gate" then dw_gate_art(p["value"])
    else icon(dw_point_icon(p))
    end
    tag.span(art, class: css, style: style.join("; ").presence)
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

  # Capa da mídia só por link seguro (https:// ou do próprio servidor).
  def dw_media_image(m) = m["image"].to_s.match?(%r{\A(https://|/)[^"'()\s<>]+\z}) ? m["image"] : nil

  def dw_color_class(w, p = nil) = "dw-#{w['color'].presence || (p && dw_light?(p) ? 'amber' : 'accent')}"

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
  def dw_command_form(p, command, w:, dashboard:, live:, &)
    form_with url: command_point_path(p["id"]), data: dw_confirm(p).merge(turbo_frame: live ? nil : "_top").compact, class: "mt-3" do |f|
      safe_join([ hidden_field_tag(:command, command, id: nil),
                  (hidden_field_tag(:dashboard_id, dashboard.id, id: nil) if live),
                  (hidden_field_tag(:widget_id, w["id"], id: nil) if live), capture(f, &) ].compact)
    end
  end

  def dw_confirm(p)
    return {} if p["confirm"].blank? && p["risk"] == "normal"

    { turbo_confirm: p["confirm"].presence || "Acionar #{p['name']}?", turbo_confirm_title: Point::RISKS.fetch(p["risk"], "Confirmar") }
  end

  def dw_number(v, unit = nil)
    return "—" if v.nil?

    [ number_with_precision(v, precision: 1, strip_insignificant_zeros: true, delimiter: "."), unit ].compact.join(" ")
  end

  # Fundo do cartão de área: a foto da área ou um dos gradientes da casa (fixo por área).
  def dw_area_art(area) = "dw-art-#{area['id'].to_s.bytes.sum % AREA_ARTS}"

  def dw_view_path(dashboard, view, home:)
    slug = view["path"].presence || view["id"]
    home ? root_path(local: dashboard.site_id, view: slug) : dashboard_path(dashboard, view: slug)
  end
end
