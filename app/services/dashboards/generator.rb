module Dashboards
  # Dashboard automático (ESQUEMA-V1 §6.3) a partir das áreas e pontos do
  # local: "Início" (luzes no topo, o que está ligado, alertas, consumo,
  # segurança, cenas e um cartão por área) e uma view por área (uma seção por
  # dispositivo). Tensão e corrente ficam de fora (ruído para quem mora); a
  # potência vai para o gráfico. Ids determinísticos (derivados dos ids dos
  # pontos e áreas) para o tempo real e o editor acharem o mesmo widget.
  class Generator
    LIGHT = /l[aâ]mpada|\bluz|\bluzes|ilumina|\bled\b|abajur|spot|pendente|arandela|plafon/i
    TECHNICAL = %w[voltage current].freeze
    TECHNICAL_UNITS = %w[V A mA].freeze

    def self.call(site) = new(site).call

    def initialize(site)
      @site = site
      @points = site.points.includes(:device).where(hidden: false, disabled: false).order(:name).to_a.reject { |p| p.device.disabled }
      @areas = site.areas.order(:position, :name).to_a
      @lights_tag = Tagging.joins(:tag).where(tags: { name: "iluminacao" }, taggable_type: "Point").pluck(:taggable_id).to_set
      @name_count = @points.map(&:name).tally
    end

    def call
      { "schema_version" => Schema::VERSION, "views" => [ home, *area_views ] }
    end

    private

    def home
      lights = @points.select { |p| light?(p) && p.capability == "onoff" }
      power = @points.select { |p| power?(p) }
      security = @points.select { |p| p.risk != "normal" || p.capability.in?(%w[gate contact motion]) }
      sections = []
      sections << section("s-home-lights", "Luzes", "light-bulb", lights.map { |p| tile(p, "wh", label: home_label(p), span: span(6, 4, 3)) }) if lights.any?
      sections << section("s-home-now", "Agora", "lightning-bolt", [
        { "id" => "w-home-on", "type" => "query_list", "label" => "Ligados agora", "query" => { "capability" => "onoff", "state" => "on" },
          "empty_text" => "Tudo desligado.", "span" => span(12, 6, 6) },
        { "id" => "w-home-alerts", "type" => "alerts", "label" => "Alertas", "span" => span(12, 6, 6) }
      ])
      if power.any?
        sections << section("s-home-energy", "Consumo", "chart-bar", [
          { "id" => "w-home-power-chart", "type" => "chart", "label" => "Potência nas últimas 24 h", "binds" => top_power(power).map(&:id),
            "range" => "24h", "span" => span(12, 12, 8) },
          { "id" => "w-home-power-now", "type" => "group", "label" => "Agora", "binds" => top_power(power).map(&:id), "span" => span(12, 12, 4) }
        ])
      end
      sections << section("s-home-security", "Segurança", "exclamation-circle", security.map { |p| tile(p, "ws", label: home_label(p), span: span(12, 6, 4)) }) if security.any?
      cameras = @points.select { |p| camera?(p) }
      sections << section("s-home-cameras", "Câmeras", "video-camera", cameras.map { |p| camera(p, "wc") }) if cameras.any?
      sections << section("s-home-scenes", "Cenas", "sparkles", [ { "id" => "w-home-scenes", "type" => "scene_bar", "span" => span(12, 12, 12) } ]) if @site.scenes.exists?
      if @areas.size > 1
        cards = @areas.map { |a| { "id" => "w-area-#{a.id}", "type" => "area_card", "area" => a.id, "span" => span(12, 6, 4) } }
        sections << section("s-home-areas", "Áreas", "view-boards", cards)
      end

      badges = [ { "id" => "b-on", "type" => "stat", "label" => "ligados", "query" => { "capability" => "onoff", "state" => "on" }, "aggregate" => "count" } ]
      badges << { "id" => "b-power", "type" => "stat", "label" => "agora", "query" => { "device_class" => "power" }, "aggregate" => "sum" } if power.any?
      { "id" => "home", "title" => "Início", "icon" => "home", "badges" => badges, "sections" => sections }
    end

    def area_views
      groups = @points.group_by(&:effective_area_id)
      views = @areas.filter_map { |a| area_view("a-#{a.id}", a.name, a.icon.presence || "view-boards", groups[a.id], area: a.id) if groups[a.id] }
      views << area_view("a-none", "Sem área", "cube", groups[nil]) if groups[nil]
      views
    end

    def area_view(id, title, icon, points, area: nil)
      useful = points.reject { |p| technical?(p) }
      sections = useful.group_by(&:device).sort_by { |d, ps| [ ps.any? { |p| light?(p) } ? 0 : 1, d.name ] }.map do |device, ps|
        ps = ps.sort_by { |p| [ p.writable ? 0 : 1, p.name ] }
        wspan = ps.size == 1 ? span(12, 12, 12) : span(6, 6, 6)
        section("s-#{id}-#{device.id}", device.name, nil, ps.map { |p| tile(p, "wa", span: wspan) }, span: span(12, 12, 6))
      end
      power = points.select { |p| power?(p) }
      if power.any?
        sections << section("s-#{id}-energy", "Consumo da área", "chart-bar",
                            [ { "id" => "w-#{id}-chart", "type" => "chart", "label" => "Potência nas últimas 24 h", "binds" => top_power(power).map(&:id), "range" => "24h", "span" => span(12, 12, 12) } ])
      end
      { "id" => id, "title" => title, "icon" => icon, "area" => area, "sections" => sections }.compact
    end

    def tile(point, prefix, span:, label: nil)
      return camera(point, prefix) if camera?(point)

      w = { "id" => "#{prefix}-#{point.id}", "type" => "tile", "bind" => point.id, "span" => span }
      w["label"] = label if label && label != point.name
      w["color"] = "amber" if light?(point)
      w["tap"] = "toggle" if point.capability == "onoff" && point.writable
      w["features"] = [ "slider" ] if point.capability.in?(%w[dimmer setpoint]) && point.writable
      w["features"] = [ "select" ] if point.capability == "enum" && point.writable
      w
    end

    def camera?(p) = p.capability == "stream" && p.device.driver == "go2rtc"
    def camera(p, prefix) = { "id" => "#{prefix}-#{p.id}", "type" => "camera", "bind" => p.id, "live" => true, "span" => span(12, 6, 6) }

    def section(id, title, icon, widgets, span: nil)
      { "id" => id, "title" => title, "icon" => icon, "span" => span, "widgets" => widgets }.compact
    end

    def span(mobile, tablet, desktop) = { "mobile" => mobile, "tablet" => tablet, "desktop" => desktop }
    def light?(p) = p.capability.in?(%w[onoff dimmer]) && (@lights_tag.include?(p.id) || p.name.match?(LIGHT) || p.device.name.match?(LIGHT))
    def power?(p) = p.capability == "measure" && (p.device_class == "power" || p.unit == "W")
    def technical?(p) = p.capability == "measure" && (TECHNICAL.include?(p.device_class) || TECHNICAL_UNITS.include?(p.unit))
    def top_power(power) = power.first(8)

    # Fora da tela do dispositivo, nome repetido ("Socket 1", "Potência") leva o dispositivo junto.
    def home_label(p) = @name_count[p.name] > 1 ? "#{p.device.name} · #{p.name}" : p.name
  end
end
