module Dashboards
  # Dashboard resolvido para quem está vendo (web e GET /api/v1/dashboards/:id):
  # a definição com os widgets que o papel não vê removidos, `visible` (estado,
  # qualidade e hora agora), `data` calculado por widget (contagens, listas,
  # alertas, cenas) e o dicionário `points` com o valor atual de cada ponto
  # usado. O app redesenha um widget trocando só a entrada de `points`.
  class Resolver
    POINT_FIELDS = %i[id key name icon capability unit risk confirm writable options quality changed_at device_class helper].freeze
    LIST_LIMIT = 24

    attr_reader :dashboard, :role

    def initialize(dashboard, role:, definition: nil)
      @dashboard = dashboard
      @site = dashboard.site
      @role = role
      @definition = definition || dashboard.published
      @all = @site.points.includes(:device).order(:name).to_a
      @by_id = @all.index_by(&:id)
      @by_key = @all.index_by(&:key)
      @used = {}
    end

    def call
      views = Array(@definition["views"]).map do |view|
        view.merge("badges" => Array(view["badges"]).filter_map { |w| resolve(w) },
                   "sections" => Array(view["sections"]).map { |s| s.merge("widgets" => Array(s["widgets"]).filter_map { |w| resolve(w) }) })
      end
      { "id" => dashboard.id, "site_id" => @site.id, "name" => dashboard.name, "kind" => dashboard.kind, "auto" => dashboard.auto,
        "version" => dashboard.version, "schema_version" => @definition["schema_version"], "role" => role,
        "can_edit" => SiteMembership.allowed?(role, :manage), "views" => views, "points" => points_payload }
    end

    # Um widget só (o quadro que o tempo real recarrega). nil = não existe ou o papel não vê.
    def widget(id)
      Array(@definition["views"]).each do |view|
        found = [ *Array(view["badges"]), *Array(view["sections"]).flat_map { |s| Array(s["widgets"]) } ].find { |w| w["id"] == id }
        return resolve(found) if found
      end
      nil
    end

    def point(ref) = ref.is_a?(String) ? (@by_id[ref] || @by_key[ref]) : nil
    def site = @site
    def points_payload = @used.transform_values { |p| point_json(p) }

    private

    def resolve(w)
      return if w.dig("visible_if", "role") && !(role == "owner" || w.dig("visible_if", "role").include?(role))

      data, deps = data_for(w)
      w.merge("visible" => visible?(w), "data" => data, "deps" => deps.map(&:id).uniq)
    end

    # [data, pontos de que o widget depende (para o tempo real)].
    def data_for(w)
      binds = [ w["bind"], *Array(w["binds"]) ].compact.filter_map { |ref| use(point(ref)) }
      deps = [ *binds, *visibility_refs(w["visible_if"]).filter_map { |ref| use(point(ref)) } ]
      case w["type"]
      when "tile" then [ tile_names(w, binds.first).merge("point_ids" => binds.map(&:id), "missing" => binds.empty? && w["bind"].present?), deps ]
      when "group", "chart", "camera" then [ { "point_ids" => binds.map(&:id), "missing" => binds.size < [ w["bind"], *Array(w["binds"]) ].compact.size }, deps ]
      when "vacuum" then vacuum(binds.first, deps)
      when "energy"
        tariff = use(point(w["tariff_point"]))
        [ Energy.new(w, binds, @site, tariff_point: tariff).call, [ *deps, tariff ].compact ]
      when "gauge" then gauge(w, binds.first, deps)
      when "stat" then stat(w, binds, deps)
      when "query_list"
        scope = query(w["query"], with_state: false)
        matched = query(w["query"]).first(LIST_LIMIT).each { |p| use(p) }
        [ { "point_ids" => matched.map(&:id), "count" => query(w["query"]).size }, deps + scope ]
      when "area_card" then area_card(w, deps)
      when "scene_bar" then [ { "scenes" => scenes(w) }, deps ]
      when "alerts" then alerts(deps)
      else plugin_data(w, binds, deps)
      end
    end

    # Widget plugin (Dashboards::Widgets, Lote 4): o plugin calcula; os pontos extras viram dependência.
    def plugin_data(w, binds, deps)
      plugin = Widgets[w["type"]] or return [ {}, deps ]
      data, extra = plugin.data(self, w, binds)
      [ data, deps + Array(extra).each { |p| use(p) } ]
    end

    # Título do tile: o rótulo próprio; o automático do Início ("Aparelho · Ponto",
    # Generator#home_label) vira título + contexto pela regra de Point#display_names.
    def tile_names(w, p)
      return { "title" => w["label"].presence || p&.name } unless p && w["label"] == "#{p.device.name} · #{p.name}"

      title, context = p.display_names
      { "title" => title, "context" => context }
    end

    def stat(w, binds, deps)
      list = w["query"] ? query(w["query"]) : binds
      agg = w["aggregate"] || (w["query"] ? "count" : "last")
      # Soma e média são "agora": leitura de aparelho sem sinal não entra (senão "0 W agora" com tudo fora do ar).
      nums = list.select { |p| agg == "count" || p.quality == "good" }.map(&:value).grep(Numeric)
      value = case agg
      when "count" then list.size
      when "sum" then nums.any? ? nums.sum.round(2) : nil
      when "avg" then nums.any? ? (nums.sum / nums.size).round(2) : nil
      when "min" then nums.min
      when "max" then nums.max
      else list.first&.value
      end
      unit = agg == "count" ? nil : list.filter_map(&:unit).first
      deps += w["query"] ? query(w["query"], with_state: false) : []
      text = w["attribute"].present? && agg == "last" ? list.first&.attrs.to_h[w["attribute"]].to_s.presence || "—" : stat_text(value, unit, agg, list.first)
      [ { "value" => value, "unit" => unit, "text" => text, "point_ids" => list.first(LIST_LIMIT).map(&:id) }, deps ]
    end

    def stat_text(value, unit, agg, first)
      return helpers.point_value_text(first) if agg == "last" && first
      return "—" if value.nil?

      [ helpers.number_with_precision(value, precision: 1, strip_insignificant_zeros: true, delimiter: "."), unit ].compact.join(" ")
    end

    def gauge(w, point, deps)
      min = (w["min"] || point&.min || 0).to_f
      max = (w["max"] || point&.max || 100).to_f
      v = point&.value
      ratio = v.is_a?(Numeric) && max > min ? ((v - min) / (max - min)).clamp(0, 1).round(4) : nil
      [ { "point_ids" => [ point&.id ].compact, "min" => min, "max" => max, "ratio" => ratio }, deps ]
    end

    # Robô: o ponto `vacuum` e os irmãos do mesmo aparelho pelo papel no
    # endereço (situação, bateria, erro, ajustes, peças), cômodos e ações.
    def vacuum(point, deps)
      return [ { "point_ids" => [], "missing" => true }, deps ] unless point&.capability == "vacuum"

      siblings = @all.select { |p| p.device_id == point.device_id && p.id != point.id && !p.disabled }.each { |p| use(p) }
      by_role = siblings.group_by { |p| p.address["role"] }
      one = ->(role) { by_role[role]&.first&.id }
      [ { "point_ids" => [ point.id ], "rooms" => Array(point.address["rooms"]), "actions" => Array(point.address["actions"]&.keys),
          "detail" => one.call("detail"), "battery" => one.call("battery"), "fault" => one.call("fault"),
          "settings" => Points::Command::VACUUM_SETTINGS.filter_map { |r| (id = one.call(r)) && [ r, id ] }.to_h,
          "parts" => [ *by_role["part"], *by_role["detergent"] ].map(&:id) }, deps + siblings ]
    end

    def area_card(w, deps)
      area = @site.areas.find_by(id: w["area"])
      return [ { "missing" => true }, deps ] unless area

      inside = @all.select { |p| p.effective_area_id == area.id && !p.hidden }
      power = inside.select { |p| p.capability == "measure" && (p.device_class == "power" || p.unit == "W") }.map(&:value).grep(Numeric)
      view = Array(@definition["views"]).find { |v| v["area"] == area.id }
      [ { "area" => { "id" => area.id, "name" => area.name, "icon" => area.icon, "background" => area.background },
          "view_id" => view&.dig("id"),
          "on" => inside.count { |p| p.capability == "onoff" && p.value == true },
          "open" => inside.count { |p| p.capability.in?(%w[contact gate]) && (p.value == true || p.value == "open") },
          "motion" => inside.any? { |p| p.capability == "motion" && p.value == true },
          "power" => power.any? ? power.sum.round(1) : nil,
          "unavailable" => inside.count { |p| p.quality != "good" },
          "total" => inside.size }, deps + inside ]
    end

    def scenes(w)
      list = @site.scenes.order(:name)
      list = list.where(id: w["scenes"]) if w["scenes"].present?
      list.map do |s|
        risk = s.risk
        { "id" => s.id, "name" => s.name, "icon" => s.icon, "confirm" => risk != "normal", "can_activate" => SiteMembership.allowed?(role, :command, risk: risk) }
      end
    end

    def alerts(deps)
      open = @site.alerts.active.includes(:alert_rule, :point).recent.limit(LIST_LIMIT).to_a
      watched_ids = @site.alert_rules.pluck(:point_id)
      watched = @all.select { |p| watched_ids.include?(p.id) }
      [ { "alerts" => open.map do |a|
        { "id" => a.id, "title" => a.alert_rule.name, "severity" => a.alert_rule.severity, "point_id" => a.point_id,
          "text" => "#{a.point.name}: #{helpers.point_value_text(a.point)}", "opened_at" => a.opened_at, "acked" => a.acked?,
          "can_ack" => SiteMembership.allowed?(role, :command, risk: "sensitive") }
      end }, deps + watched ]
    end

    # Filtros do `Points::Query` (Lote 4, G8: também integração, há quanto
    # tempo mudou, faixa, exclusão, ordem e corte). Sem `state`, a lista dos
    # pontos que podem entrar (dependência do tempo real).
    def query(q, with_state: true)
      @queries ||= {}
      @queries[[ q, with_state ]] ||= (@point_query ||= Points::Query.new(@site, points: @all)).call(q || {}, with_state: with_state)
    end

    def on?(p) = p.value == true || p.value == "open"

    # Regras do visible_if avaliadas aqui (todas valem: E); `any` = OU. Papel
    # sai em `resolve`; tela (`screen`) e aparelho (`device`) são da tela/app.
    VISIBILITY = { "state" => :state_ok?, "numeric" => :numeric_ok?, "quality" => :quality_ok?, "time" => :time_ok?, "any" => :any_ok? }.freeze

    def visible?(w) = condition_ok?(w["visible_if"], w)

    def condition_ok?(cond, w)
      return true unless cond.is_a?(Hash)

      cond.all? { |k, v| (m = VISIBILITY[k]).nil? || send(m, v, w) }
    end

    def state_ok?(st, _w) = (p = point(st["point"])) && Array(st["is"]).map(&:to_s).include?(p.value.to_s) || false

    def numeric_ok?(n, _w)
      v = point(n["point"])&.value
      v.is_a?(Numeric) && (n["above"].nil? || v > n["above"]) && (n["below"].nil? || v < n["below"])
    end

    def quality_ok?(q, w) = (p = point(w["bind"] || Array(w["binds"]).first)) && Array(q).include?(p.quality) || false
    def any_ok?(list, w) = Array(list).any? { |c| condition_ok?(c, w) }

    # Pontos citados no visible_if (dependências do tempo real), inclusive dentro do `any`.
    def visibility_refs(cond)
      return [] unless cond.is_a?(Hash)

      [ cond.dig("state", "point"), cond.dig("numeric", "point"), *Array(cond["any"]).flat_map { |c| visibility_refs(c) } ].compact
    end

    # Janela que pode passar da meia-noite ("18:00" a "06:00"), no fuso do local.
    def time_ok?(t, _w = nil)
      now = Time.current.in_time_zone(@site.timezone).strftime("%H:%M")
      after = t["after"] || "00:00"
      before = t["before"] || "24:00"
      after <= before ? now >= after && now < before : now >= after || now < before
    end

    def use(p)
      @used[p.id] = p if p
      p
    end

    def point_json(p) = self.class.point_json(p, role)

    # O ponto como o app desenha (valor, texto, comandos e se este papel comanda);
    # também é o `?view=app` de GET /devices/:id/points.
    def self.point_json(p, role)
      helpers = ApplicationController.helpers
      on = p.value == true || p.value == "open"
      title, context = p.display_names
      json = p.slice(*POINT_FIELDS).merge(
        "value" => p.value, "text" => helpers.point_value_text(p), "on" => on, "area_id" => p.effective_area_id,
        "device" => p.device.name, "min" => p.min&.to_f, "max" => p.max&.to_f, "step" => p.step&.to_f,
        "commands" => (cmds = Points::Command.commands_for(p)), "actions" => Points::Command.actions_for(p),
        "mode" => p.address["mode"], "input" => helpers.point_input_type(p),
        "can_command" => p.writable && !p.disabled && !p.device.disabled && Drivers.supported?(p.device) && cmds.any? &&
                         SiteMembership.allowed?(role, :command, risk: p.risk),
        "title" => title, "context" => context, "status_note" => helpers.point_status_note(p)
      ).stringify_keys
      json.merge("display_icon" => helpers.dw_point_icon(json))
    end

    def helpers = ApplicationController.helpers
  end
end
