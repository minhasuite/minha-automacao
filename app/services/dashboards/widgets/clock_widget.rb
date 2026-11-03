module Dashboards
  module Widgets
    # Relógio (ondaB2 B10; o `clock` do HA): hora do local (fuso dele, não o
    # do navegador), com segundos e data opcionais, 24 h ou 12 h e três tamanhos.
    class ClockWidget < Base
      SIZES = %w[small medium large].freeze
      describe type: "clock", label: "Relógio", icon: "clock", params: %w[format seconds show_date size]
      texts en: { label: "Clock", bad: "format is 24h or 12h and size small, medium or large" },
            es: { label: "Reloj", bad: "format es 24h o 12h y size small, medium o large" },
            "pt-BR" => { bad: "format é 24h ou 12h e size small, medium ou large" }

      def self.gestures? = true
      def self.form = "web/dashboards/widget_forms/cards"
      def self.errors(w) = (w.key?("format") && !%w[24h 12h].include?(w["format"])) || (w.key?("size") && !SIZES.include?(w["size"])) ? [ text(:bad) ] : []

      def self.data(r, w, _binds)
        zone = ActiveSupport::TimeZone[r.site.timezone] || Time.zone
        [ { "tz" => zone.tzinfo.identifier, "now" => Time.current.in_time_zone(zone).iso8601, "format" => w["format"] || "24h", "seconds" => w["seconds"] == "1",
            "show_date" => w["show_date"] != "0", "size" => w["size"] || "medium" }, [] ]
      end
    end
  end
end
