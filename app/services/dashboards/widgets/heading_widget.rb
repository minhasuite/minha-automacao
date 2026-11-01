module Dashboards
  module Widgets
    # Título (F5) entre os widgets; sem título próprio, o rótulo.
    class HeadingWidget < Base
      describe type: "heading", label: "Título", icon: "document-text", required: %w[title], params: %w[title]

      def self.data(_r, _w, _binds) = [ {}, [] ]
      def self.attrs(p, _site = nil) = { "title" => p[:title].presence || p[:label].presence }
      def self.form = "web/dashboards/widget_forms/heading"
    end
  end
end
