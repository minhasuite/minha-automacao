module Automations
  module TriggerTypes
    # Algo com posição entrou ou saiu de uma zona (ondaA1; o `geo_location`
    # do HA). Vale para qualquer ponto que traga latitude e longitude nos
    # atributos (terremoto, raio, avião, rastreador), filtrando pela
    # integração de origem (`source`, o "platform" do HA) se pedir. O
    # Point#report_attrs! avisa cada plugin (`attrs_changed`); aqui a posição
    # nova que cruza a borda de uma zona vira o evento "geo_location".
    class GeoLocationTrigger < Base
      describe key: "geo_location", label: "Algo com posição entrou ou saiu de zona", defaults: { "event" => "enter" },
               fields: [ f("zone", :point, "Zona", required: true, en: "Zone", es: "Zona"),
                         f("event", :select, "Quando", required: true, options: -> { ZoneTrigger.events }, en: "When", es: "Cuándo"),
                         f("source", :text, "Só da integração (opcional, ex.: usgs)", en: "Only from integration (optional, e.g. usgs)", es: "Solo de la integración (opcional, ej.: usgs)") ]
      texts "pt-BR" => { title: { enter: "Entrou na zona", leave: "Saiu da zona" } },
            en: { label: "Something with a location entered or left a zone", title: { enter: "Entered the zone", leave: "Left the zone" } },
            es: { label: "Algo con ubicación entró o salió de una zona", title: { enter: "Entró en la zona", leave: "Salió de la zona" } }

      def self.event = "geo_location"
      def self.fires_on_event?(t, p) = p["zone"] == t["zone"] && p["move"] == t["event"] && (t["source"].blank? || t["source"] == p["source"])
      def self.title(t) = t["event"].in?(%w[enter leave]) ? text("title.#{t['event']}") : label
      def self.event_info(t, p) = { "type" => key, "title" => title(t), "point" => p["point"], "name" => p["name"], "source" => p["source"],
                                    "latitude" => p["latitude"], "longitude" => p["longitude"] }.compact

      def self.coords(attrs)
        lat = Float(attrs.to_h["latitude"].to_s, exception: false)
        lon = Float(attrs.to_h["longitude"].to_s, exception: false)
        [ lat, lon ] if lat && lon
      end

      def self.attrs_changed(point, was)
        now = coords(point.attrs)
        old = coords(was)
        return if now.nil? || now == old || point.helper.present?
        return unless Automation.where(site_id: point.site_id, enabled: true).exists?([ "definition->'triggers' @> ?", [ { type: key } ].to_json ])

        People.zones(point.site).each do |z|
          c = HelperTypes::Zone.center(z) or next
          inside = ->(ll) { ll.present? && People.distance(*ll, *c) <= HelperTypes::Zone.radius(z) }
          next if inside[now] == inside[old]

          Triggers.event(point.site_id, event, { "zone" => z.id, "move" => inside[now] ? "enter" : "leave", "point" => point.id, "name" => point.name,
                                                 "source" => point.device&.integration&.driver || point.device&.driver, "latitude" => now[0], "longitude" => now[1] }.compact)
        end
      end
    end
  end
end
