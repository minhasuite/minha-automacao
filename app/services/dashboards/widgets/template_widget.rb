module Dashboards
  module Widgets
    # Modelo de card (P1.3): `{type: "template", template: "<chave>", vars: {...}}`.
    # O modelo (do local ou embutido; `Dashboards::CardTemplates`) é resolvido
    # inteiro aqui: o `data` traz o desenho (`layout`) e os espaços prontos
    # (title, subtitle, icon, image, value, facts, tone, tap), e a web e o app
    # desenham o mesmo genérico, sem saber o que o card é.
    class TemplateWidget < Base
      describe type: "template", label: "Modelo de card", icon: "template", required: %w[template], params: %w[template]
      texts en: { label: "Card template", bad_key: "template must be the key of a card template", bad_vars: "vars must be an object of simple values (up to %{max})" },
            es: { label: "Plantilla de tarjeta", bad_key: "template debe ser la clave de una plantilla de tarjeta",
                  bad_vars: "vars debe ser un objeto de valores simples (hasta %{max})" },
            "pt-BR" => { bad_key: "template precisa ser a chave de um modelo de card", bad_vars: "vars precisa ser um objeto de valores simples (até %{max})" }

      MAX_VARS = 16

      def self.errors(w)
        e = []
        e << text(:bad_key) unless w["template"].to_s.match?(CardTemplates::KEY)
        if w.key?("vars")
          ok = w["vars"].is_a?(Hash) && w["vars"].size <= MAX_VARS && w["vars"].values.all? { |v| v.nil? || v.is_a?(String) || v.is_a?(Numeric) || v == true || v == false }
          e << text(:bad_vars, max: MAX_VARS) unless ok
        end
        e
      end

      def self.data(r, w, _binds) = CardTemplates.render(r, CardTemplates.find(r.site, w["template"]), w["vars"], widget: w)

      # Ideia 14: os pontos de um item do modelo (o toque na pílula).
      def self.drill(r, w, key)
        t = CardTemplates.find(r.site, w["template"]) or return nil
        CardTemplates.drill(r, t, w["vars"], key)
      end

      def self.attrs(p, _site = nil)
        vars = p[:vars].respond_to?(:to_unsafe_h) ? p[:vars].to_unsafe_h : p[:vars].to_h
        { "template" => p[:template].presence, "vars" => vars.transform_values { |v| v.to_s.strip }.compact_blank.presence }.compact
      end

      def self.permit = [ :template, { vars: {} } ]
      def self.form = "web/dashboards/widget_forms/template"
    end
  end
end
