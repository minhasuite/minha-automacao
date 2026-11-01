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
    return "lightning-bolt" if p["device_class"] == "power" || p["unit"] == "W"
    return "switch-horizontal" if p["capability"] == "onoff"

    PointsHelper::POINT_ICONS.fetch(p["capability"], "cube")
  end

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
