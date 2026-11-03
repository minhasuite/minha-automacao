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
        view.merge({ "theme_now" => theme_now(view) }.compact).merge("badges" => Array(view["badges"]).filter_map { |w| resolve(w) },
                   "sections" => Array(view["sections"]).map { |s| s.merge("widgets" => Array(s["widgets"]).filter_map { |w| resolve(w) }) })
      end
      { "id" => dashboard.id, "site_id" => @site.id, "name" => dashboard.name, "kind" => dashboard.kind, "auto" => dashboard.auto,
        "version" => dashboard.version, "schema_version" => @definition["schema_version"], "role" => role,
        "can_edit" => SiteMembership.allowed?(role, :manage), "views" => views, "points" => points_payload }.merge(@definition.slice("theme"))
    end

    # Um widget só (o quadro que o tempo real recarrega). nil = não existe ou o papel não vê.
    def widget(id)
      Array(@definition["views"]).each do |view|
        found = Resolver.flatten([ *Array(view["badges"]), *Array(view["sections"]).flat_map { |s| Array(s["widgets"]) } ]).find { |w| w["id"] == id }
        return resolve(found) if found
      end
      nil
    end

    # O que os plugins de widget (Dashboards::Widgets) usam para calcular o `data`.
    def point(ref) = ref.is_a?(String) ? (@by_id[ref] || @by_key[ref]) : nil
    def site = @site
    def points = @all
    def definition = @definition
    def points_payload = @used.transform_values { |p| point_json(p) }

    # Filtros do `Points::Query` (Lote 4, G8: também integração, há quanto
    # tempo mudou, faixa, exclusão, ordem e corte). Sem `state`, a lista dos
    # pontos que podem entrar (dependência do tempo real).
    def query(q, with_state: true)
      @queries ||= {}
      @queries[[ q, with_state ]] ||= (@point_query ||= Points::Query.new(@site, points: @all)).call(q || {}, with_state: with_state)
    end

    # Põe o ponto no `points` do JSON (o que o widget desenha).
    def use(p)
      @used[p.id] = p if p
      p
    end

    private

    # app3: o tema que vale agora na visão (painel + visão, noite no fuso do
    # local), já com as cores, para o app desenhar sem repetir a regra.
    def theme_now(view)
      t = Themes.resolve(@definition, view, @site) or return
      th = t["theme"]
      { "key" => th.key, "label" => th.label, "accent" => th.accent, "accent2" => th.accent2, "glass" => t["glass"],
        "night" => t["night"], "image" => t["image"], "blur" => t["blur"] }.compact
    end

    def resolve(w)
      return if w.dig("visible_if", "role") && !(role == "owner" || w.dig("visible_if", "role").include?(role))

      return container(w) if w["widgets"].is_a?(Array)

      data, deps = data_for(w)
      gestures = Actions.resolve(self, w, [ w["bind"] ].compact.filter_map { |ref| point(ref) })
      deps += gestures.values.filter_map { |g| point(g["point_id"]) }
      w.merge("visible" => visible?(w), "data" => data, "deps" => deps.map(&:id).uniq).merge(gestures.any? ? { "gestures" => gestures } : {})
    end

    # [data, pontos de que o widget depende (para o tempo real)]: o plugin do
    # tipo (Dashboards::Widgets) calcula; os pontos extras viram dependência.
    def data_for(w)
      binds = [ w["bind"], *Array(w["binds"]) ].compact.filter_map { |ref| use(point(ref)) }
      deps = [ *binds, *visibility_refs(w["visible_if"]).filter_map { |ref| use(point(ref)) } ]
      plugin = Widgets[w["type"]] or return [ {}, deps ]
      data, extra = plugin.data(self, w, binds)
      [ data, deps + Array(extra) ]
    end

    # Pilha/grade (ondaB2 B8): resolve os de dentro; cada um tem o próprio quadro de tempo real.
    def container(w)
      w.merge("visible" => visible?(w), "data" => {}, "deps" => visibility_refs(w["visible_if"]).filter_map { |ref| use(point(ref))&.id },
              "widgets" => w["widgets"].filter_map { |c| resolve(c) })
    end

    # Widgets com os de dentro das pilhas.
    def self.flatten(list) = list.flat_map { |w| [ w, *flatten(Array(w["widgets"])) ] }

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
  end
end
