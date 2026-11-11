module Dashboards
  # Ações de toque, de segurar e de duplo toque (ondaB2 B9; `tap_action`,
  # `hold_action`, `double_tap_action` do HA), por registro: ação nova =
  # classe que herda de `Base` + nome em `PLUGINS`. No JSON de qualquer widget:
  #
  #   "tap_action": { "action": "navigate", "navigation_path": "cozinha" },
  #   "hold_action": { "action": "more_info" },
  #   "double_tap_action": { "action": "command", "point": "<id>", "command": "run", "confirmation": true }
  #
  # O Resolver põe em `gestures` ({tap, hold, double_tap}) o que a tela
  # precisa (o ponto já com permissão); a web (`dw-gesture`) e o app executam.
  # Sem `tap_action`, o tile segue o `tap` antigo (toggle/more_info/none).
  module Actions
    GESTURES = { "tap" => "tap_action", "hold" => "hold_action", "double_tap" => "double_tap_action" }.freeze
    PLUGINS = %w[Toggle MoreInfo Navigate Url Command CommandQuery Assist None].freeze
    # Ideia 12: botões rápidos em qualquer widget (`quick_actions`: até 4 ações
    # com `label` e `icon`), ex. "Apagar tudo" no cartão de área.
    QUICK = "quick_actions"
    MAX_QUICK = 4
    URL = %r{\Ahttps://[^\s"'<>]+\z}
    PATH = %r{\A(/[\w\-/.?=&%]*|[a-z0-9][a-z0-9-]{0,39})\z}

    module_function

    def plugins = PLUGINS.map { |n| const_get(n) }
    def [](key) = plugins.find { |a| a.key == key.to_s }

    def errors(w) = gesture_errors(w) + quick_errors(w)

    def quick_errors(w)
      return [] unless w.key?(QUICK)

      list = w[QUICK]
      return [ I18n.t("dashboards.schema.quick_list", max: MAX_QUICK) ] unless list.is_a?(Array) && list.size.between?(1, MAX_QUICK)

      list.each_with_index.filter_map do |a, i|
        plugin = a.is_a?(Hash) && self[a["action"]]
        next I18n.t("dashboards.schema.action_unknown", field: "#{QUICK}[#{i}]") unless plugin
        next I18n.t("dashboards.schema.quick_label", n: i + 1) unless a["label"].is_a?(String) && a["label"].strip.size.between?(1, 40) && (a["icon"].nil? || a["icon"].is_a?(String))

        msg = plugin.errors(a) and I18n.t("dashboards.schema.action_bad", field: "#{QUICK}[#{i}]", msg: msg)
      end
    end

    # Botões rápidos do widget: os dele ou, sem nenhum, o padrão do local para o tipo
    # (`sites.settings.dashboard_defaults.quick_actions` = {tipo → lista}; Configurações → Painéis → Padrões).
    def quick_list(site, w)
      return Array(w[QUICK]) if w.key?(QUICK)

      list = site&.settings.to_h.dig("dashboard_defaults", "quick_actions", w["type"].to_s)
      list.is_a?(Array) ? list : []
    end

    # A ação de um lugar do widget: "tap"/"hold"/"double_tap" ou "quick-<n>" (botão rápido).
    def slot(w, name, site: nil)
      return w[GESTURES[name]] if GESTURES.key?(name)

      n = name.to_s[/\Aquick-(\d)\z/, 1] or return
      quick_list(site, w)[n.to_i]
    end

    # Botões rápidos resolvidos ([{action, label, icon, slot, ...payload}]), só os que têm o que fazer.
    def resolve_quick(r, w, binds)
      quick_list(r.site, w).each_with_index.filter_map do |a, i|
        plugin = a.is_a?(Hash) && self[a["action"]] or next
        payload = plugin.payload(r, a.merge("_scope" => scope(w)), binds.first) or next
        confirm = a["confirmation"].is_a?(String) ? a["confirmation"] : payload["confirm"]
        { "action" => plugin.key, "label" => a["label"], "icon" => a["icon"], "slot" => "quick-#{i}" }.merge(payload).merge({ "confirm" => confirm }.compact).compact
      end
    end

    # O que o widget junta às consultas das ações em lote (o cartão de área: a área).
    def scope(w) = w["area"].is_a?(String) ? { "area" => w["area"] } : {}

    def gesture_errors(w)
      GESTURES.values.filter_map do |field|
        next unless w.key?(field)

        a = w[field]
        plugin = a.is_a?(Hash) && self[a["action"]]
        next I18n.t("dashboards.schema.action_unknown", field: field) unless plugin
        next I18n.t("dashboards.schema.action_confirmation", field: field) if a.key?("confirmation") && ![ true, false ].include?(a["confirmation"]) && !a["confirmation"].is_a?(String)

        msg = plugin.errors(a) and I18n.t("dashboards.schema.action_bad", field: field, msg: msg)
      end
    end

    FORM = %w[action navigation_path url point command value confirmation query].freeze

    # Formulário do editor ({gesto → campos}) → as props `*_action` (vazio = padrão do widget).
    def from_form(form)
      GESTURES.to_h do |gesture, field|
        f = form[gesture].to_h
        plugin = self[f["action"]]
        a = plugin && { "action" => plugin.key }.merge(f.slice(*plugin.fields).compact_blank)
        a["confirmation"] = true if a && f["confirmation"] == "1"
        [ field, a ]
      end
    end

    # {gesto → payload} do widget (só os gestos configurados).
    def resolve(r, w, binds)
      GESTURES.filter_map do |gesture, field|
        a = w[field]
        plugin = a.is_a?(Hash) && self[a["action"]] or next
        payload = plugin.payload(r, a.merge("_scope" => scope(w)), binds.first) or next
        confirm = a["confirmation"].is_a?(String) ? a["confirmation"] : (I18n.t("dashboards.act.sure") if a["confirmation"] == true)
        confirm ||= payload["confirm"]
        [ gesture, { "action" => plugin.key }.merge(payload).merge({ "confirm" => confirm }.compact) ]
      end.to_h
    end

    def point_payload(r, p)
      return unless p

      r.use(p)
      { "point_id" => p.id }
    end

    class Base
      extend PluginTexts
      translates :label

      class << self
        attr_reader :key, :icon

        # fields: o que o editor pede (navigation_path, url, point, command, value).
        def describe(key:, label:, icon:, fields: [])
          @key = key
          @label = label
          @icon = icon
          @fields = fields.freeze
        end

        def fields = @fields || []
        def errors(_a) = nil
        def payload(_r, _a, _point) = {}
      end
    end

    class Toggle < Base
      describe key: "toggle", label: "Alternar", icon: "switch-horizontal", fields: %w[point]
      texts en: { label: "Toggle" }, es: { label: "Alternar" }
      def self.payload(r, a, point) = Actions.point_payload(r, a["point"] ? r.point(a["point"]) : point)&.merge("command" => "toggle")
    end

    class MoreInfo < Base
      describe key: "more_info", label: "Abrir detalhes", icon: "information-circle", fields: %w[point]
      texts en: { label: "Open details" }, es: { label: "Abrir detalles" }
      def self.payload(r, a, point) = Actions.point_payload(r, a["point"] ? r.point(a["point"]) : point)
    end

    # Outra visão do painel (caminho ou id) ou uma tela do próprio sistema ("/...").
    class Navigate < Base
      describe key: "navigate", label: "Ir para", icon: "arrow-right", fields: %w[navigation_path]
      texts en: { label: "Navigate", bad: "navigation_path must be a view path or /screen" },
            es: { label: "Ir a", bad: "navigation_path debe ser el camino de una vista o /pantalla" },
            "pt-BR" => { bad: "navigation_path precisa ser o caminho de uma visão ou /tela" }
      def self.errors(a) = a["navigation_path"].to_s.match?(PATH) && !a["navigation_path"].to_s.start_with?("//") ? nil : text(:bad)
      def self.payload(_r, a, _point) = { "path" => a["navigation_path"] }
    end

    class Url < Base
      describe key: "url", label: "Abrir link", icon: "external-link", fields: %w[url]
      texts en: { label: "Open link", bad: "url must start with https://" }, es: { label: "Abrir enlace", bad: "url debe empezar con https://" },
            "pt-BR" => { bad: "url precisa começar com https://" }
      def self.errors(a) = a["url"].to_s.match?(URL) ? nil : text(:bad)
      def self.payload(_r, a, _point) = { "url" => a["url"] }
    end

    # Qualquer comando de qualquer ponto (o `perform-action` do HA: script, cena por ponto, valor).
    class Command < Base
      describe key: "command", label: "Mandar comando", icon: "lightning-bolt", fields: %w[point command value]
      texts en: { label: "Send command", bad: "command needs point and command" }, es: { label: "Enviar comando", bad: "command necesita point y command" },
            "pt-BR" => { bad: "command precisa de point e command" }
      def self.errors(a) = a["point"].is_a?(String) && a["command"].to_s.match?(/\A[a-z_]{1,40}\z/) ? nil : text(:bad)

      def self.payload(r, a, _point)
        p = r.point(a["point"]) or return
        accepted = (Points::Command.commands_for(p) + Points::Command.actions_for(p)).include?(a["command"])
        Actions.point_payload(r, p).merge("command" => a["command"], "value" => a["value"]).compact.tap do |h|
          h["can_command"] = accepted && Resolver.point_json(p, r.role)["can_command"]
          h["confirm"] = p.confirm.presence || I18n.t("points.confirm", name: p.name) if p.confirm.present? || p.risk != "normal"
        end
      end
    end

    # Ideia 12: o mesmo comando em todos os pontos de uma consulta (`Points::Query`;
    # no cartão de área a área entra sozinha), como a ação "Comandar pontos por
    # consulta" das automações. O toque vai para `Dashboards::Batch` (papel x risco
    # por ponto; crítico nunca vai em lote) e sempre pede confirmação com a contagem.
    class CommandQuery < Base
      describe key: "command_query", label: "Comandar vários (consulta)", icon: "collection", fields: %w[query command value]
      texts en: { label: "Command many (query)", bad: "command_query needs a valid query and command" },
            es: { label: "Enviar a varios (consulta)", bad: "command_query necesita consulta y comando válidos" },
            "pt-BR" => { bad: "command_query precisa de consulta e comando válidos" }

      def self.errors(a)
        ok = a["command"].to_s.match?(/\A[a-z_]{1,40}\z/) && (a["query"].is_a?(Hash) || a["query"].is_a?(String)) && a["query"].present? && Points::Query.error(a["query"]).nil?
        ok ? nil : text(:bad)
      end

      def self.payload(r, a, _point)
        targets = Batch.targets(r, a)
        allowed = targets.count { |p| Batch.allowed?(r.role, p) }
        { "command" => a["command"], "count" => targets.size, "allowed" => allowed, "can_command" => allowed.positive?,
          "confirm" => I18n.t("dashboards.batch.confirm", n: allowed, label: a["label"].presence || a["command"]) }
      end
    end

    class Assist < Base
      describe key: "assist", label: "Abrir o assistente", icon: "microphone"
      texts en: { label: "Open the assistant" }, es: { label: "Abrir el asistente" }
    end

    class None < Base
      describe key: "none", label: "Nada", icon: "ban"
      texts en: { label: "Nothing" }, es: { label: "Nada" }
    end
  end
end
