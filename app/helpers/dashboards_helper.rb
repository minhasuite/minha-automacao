# Widgets de dashboard na web (o JSON resolvido por Dashboards::Resolver).
module DashboardsHelper
  DEFAULT_SPAN = { "mobile" => 12, "tablet" => 6, "desktop" => 4 }.freeze
  SECTION_SPAN = { "mobile" => 12, "tablet" => 12, "desktop" => 12 }.freeze
  AREA_ARTS = 6
  WIDGET_ICONS = { "tile" => "light-bulb", "group" => "view-list", "stat" => "calculator", "gauge" => "clock", "chart" => "chart-bar",
                   "query_list" => "filter", "area_card" => "home", "scene_bar" => "sparkles", "alerts" => "exclamation-circle",
                   "heading" => "document-text", "markdown" => "document-text" }.freeze

  # Largura no grid de 12 colunas por tela, em variáveis CSS (.dw-w).
  def dw_span_style(span, default = DEFAULT_SPAN)
    s = default.merge(span || {})
    "--m: #{s['mobile']}; --t: #{s['tablet']}; --d: #{s['desktop']}"
  end

  def dw_light?(p) = p["capability"].in?(%w[onoff dimmer]) && "#{p['name']} #{p['device']}".match?(Dashboards::Generator::LIGHT)

  def dw_point_icon(p)
    return "light-bulb" if dw_light?(p)
    return "lightning-bolt" if p["device_class"] == "power" || p["unit"] == "W"
    return "switch-horizontal" if p["capability"] == "onoff"

    PointsHelper::POINT_ICONS.fetch(p["capability"], "cube")
  end

  def dw_color_class(w, p = nil) = "dw-#{w['color'].presence || (p && dw_light?(p) ? 'amber' : 'accent')}"

  # Linha de lista: medição com nome genérico ("Potência") leva o dispositivo na frente.
  def dw_row_names(p) = p["capability"] == "measure" ? [ p["device"], p["name"] ] : [ p["name"], p["device"] ]
  def dw_label(w, p) = w["label"].presence || p["name"]

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
    home ? root_path(local: dashboard.site_id, view: view["id"]) : dashboard_path(dashboard, view: view["id"])
  end
end
