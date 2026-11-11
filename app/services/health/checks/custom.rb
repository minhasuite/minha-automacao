module Health
  module Checks
    # Verificações personalizadas (P3): cada `CustomHealthCheck` ligado vira um
    # item, com a severidade do registro quando há problema. Com "error", o
    # `HealthCheckJob` avisa uma vez por dia (o mesmo `dedup_key` das outras).
    # Registro com consulta ou expressão quebrada fica em atenção com o erro,
    # sem derrubar os outros.
    class Custom < Check
      describe key: "custom", label: "Personalizadas", icon: "adjustments"
      texts "pt-BR" => { empty: "Nenhuma verificação personalizada", broken: "Não deu para verificar: %{error}", edit: "Editar verificação" },
            en: { label: "Custom", empty: "No custom checks", broken: "Couldn't check: %{error}", edit: "Edit check" },
            es: { label: "Personalizadas", empty: "Ninguna verificación personalizada", broken: "No se pudo verificar: %{error}", edit: "Editar verificación" }

      def self.items(_tenant)
        list = CustomHealthCheck.enabled.includes(:site).order(:name).to_a
        return [ item(key: "none", status: "ok", title: text(:empty)) ] if list.empty?

        list.map { |c| item_for(c) }
      end

      def self.item_for(check)
        fix = { label: text(:edit), url: Rails.application.routes.url_helpers.edit_settings_health_check_path(check) }
        title = "#{check.name} (#{check.site.name})"
        res, error = check.preview
        return item(key: check.id, status: "warn", title: title, detail: text(:broken, error: error), fix: fix) if error

        item(key: check.id, status: res[:problem] ? check.severity : "ok", title: title, detail: res[:detail], fix: (fix if res[:problem]))
      end
    end
  end
end
