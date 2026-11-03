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
    PLUGINS = %w[Toggle MoreInfo Navigate Url Command Assist None].freeze
    URL = %r{\Ahttps://[^\s"'<>]+\z}
    PATH = %r{\A(/[\w\-/.?=&%]*|[a-z0-9][a-z0-9-]{0,39})\z}

    module_function

    def plugins = PLUGINS.map { |n| const_get(n) }
    def [](key) = plugins.find { |a| a.key == key.to_s }

    def errors(w)
      GESTURES.values.filter_map do |field|
        next unless w.key?(field)

        a = w[field]
        plugin = a.is_a?(Hash) && self[a["action"]]
        next I18n.t("dashboards.schema.action_unknown", field: field) unless plugin
        next I18n.t("dashboards.schema.action_confirmation", field: field) if a.key?("confirmation") && ![ true, false ].include?(a["confirmation"]) && !a["confirmation"].is_a?(String)

        msg = plugin.errors(a) and I18n.t("dashboards.schema.action_bad", field: field, msg: msg)
      end
    end

    FORM = %w[action navigation_path url point command value confirmation].freeze

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
        payload = plugin.payload(r, a, binds.first) or next
        confirm = a["confirmation"].is_a?(String) ? a["confirmation"] : (I18n.t("dashboards.act.sure") if a["confirmation"] == true)
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
