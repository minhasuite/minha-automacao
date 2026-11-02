module Dashboards
  module Widgets
    # Mapa (o cartão de mapa do HA): pessoas e zonas do local, com o trajeto
    # do dia (`track`, padrão true). Quem não pode ver onde as pessoas estão
    # (Maps::MIN_ROLE) recebe só o aviso, sem coordenada nenhuma no JSON.
    class MapWidget < Base
      describe type: "map", label: "Mapa", icon: "map", params: %w[track height]

      def self.errors(w)
        e = []
        e << "track precisa ser true ou false" if w.key?("track") && ![ true, false ].include?(w["track"])
        e << "height precisa ser de 180 a 800" if w.key?("height") && !(w["height"].is_a?(Integer) && w["height"].between?(180, 800))
        e
      end

      def self.data(r, w, _binds)
        return [ { "hidden" => true }, [] ] unless Maps.allowed_role?(r.role)

        persons = People.persons(r.site).to_a
        persons.each { |p| r.use(p) }
        [ Maps.data(r.site, track: w["track"] != false).merge("point_ids" => persons.map(&:id)), persons ]
      end

      def self.attrs(p, _site = nil)
        { "track" => (false if p[:track] == "0"), "height" => (p[:height].to_i.clamp(180, 800) if p[:height].present?) }.compact
      end

      def self.form = "web/dashboards/widget_forms/map"
    end
  end
end
