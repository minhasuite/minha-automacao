module Dashboards
  module Widgets
    # Texto (F5) com Liquid (Lote 4, G18a; o `markdown` com Jinja do HA): o
    # mesmo Liquid das automações (`{{ points["sala.luz"].text }}`,
    # `{{ now | date: "%H:%M" }}`, `{% if %}`/`{% for %}`), renderizado para
    # quem vê. Os pontos citados entram nas dependências (o texto se refaz
    # quando eles mudam). Formatação: o subconjunto de Markdown de `dw_markdown`.
    class MarkdownWidget < Base
      describe type: "markdown", label: "Texto", icon: "document-text", required: %w[text], params: %w[text]
      texts en: { "label" => "Text", "bad_liquid" => "text with invalid Liquid: %{error}" },
            es: { "label" => "Texto", "bad_liquid" => "texto con Liquid no válido: %{error}" },
            "pt-BR" => { "bad_liquid" => "texto com Liquid inválido: %{error}" }

      MAX = 4000
      REF = /points(?:\[\s*["']([^"']+)["']\s*\]|\.([a-z0-9_]+(?:\.[a-z0-9_]+)*))/

      def self.errors(w)
        Liquid::Template.parse(w["text"].to_s, error_mode: :strict)
        []
      rescue Liquid::Error => e
        [ text(:bad_liquid, error: e.message.delete_prefix('Liquid syntax error: ').truncate(120)) ]
      end

      def self.form = "web/dashboards/widget_forms/markdown"

      def self.data(r, w, _binds)
        text = w["text"].to_s
        deps = text.scan(REF).filter_map { |a, b| r.use(r.point(a || b)) }
        return [ { "text" => text }, deps ] unless text.include?("{{") || text.include?("{%")

        [ { "text" => Automations::Context.new(site: r.site).render(text, limit: MAX) }, deps ]
      rescue Automations::Context::Error => e
        [ { "text" => text, "error" => e.message }, deps ]
      end
    end
  end
end
