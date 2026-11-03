module Dashboards
  module Widgets
    # Página da web (ondaB2 B10; o `iframe` do HA): só https://, num iframe
    # com sandbox, sem referer e com carregamento preguiçoso. O link nunca
    # recebe dados do painel.
    class IframeWidget < Base
      URL = %r{\Ahttps://[^\s"'<>]+\z}
      describe type: "iframe", label: "Página da web", icon: "globe-alt", required: %w[url], params: %w[url aspect]
      texts en: { label: "Web page", bad_url: "url must start with https://" }, es: { label: "Página web", bad_url: "url debe empezar con https://" },
            "pt-BR" => { bad_url: "url precisa começar com https://" }

      def self.form = "web/dashboards/widget_forms/cards"

      def self.errors(w)
        e = []
        e << text(:bad_url) unless w["url"].to_s.match?(URL)
        e << ImageWidget.text(:bad_aspect) if w.key?("aspect") && !ImageWidget::ASPECTS.key?(w["aspect"])
        e
      end

      def self.data(_r, w, _binds) = [ { "url" => (w["url"] if w["url"].to_s.match?(URL)), "ratio" => ImageWidget::ASPECTS.fetch(w["aspect"] || "16:9") }.compact, [] ]
    end
  end
end
