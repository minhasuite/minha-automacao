module HelperTypes
  # Proximidade (proximity do HA, resto): distância de quem é rastreado
  # (celular, pessoa, rastreador: qualquer ponto com latitude/longitude nos
  # atributos) até uma zona, e a direção: chegando, se afastando, parado ou
  # na zona. Movimento menor que a tolerância não muda a direção (GPS que
  # oscila parado). Valor = metros (ou km); atributos `direction` e `in_zone`.
  class Proximity < Plugin
    describe key: "proximity", title: "Proximidade", icon: "location-marker", capability: "measure",
             description: "Quão longe alguém está de uma zona (casa, trabalho) e se está chegando ou se afastando."
    fields %i[source zone tolerance_m unit]
    texts "pt-BR" => { "form.source" => "Quem é rastreado", "form.zone" => "Zona", "form.tolerance_m" => "Tolerância (m)", "form.unit" => "Unidade",
                       "hint.tolerance_m" => "Andou menos que isso entre duas leituras: a direção não muda.",
                       pick: "Escolha quem é rastreado (com localização) e a zona.", tolerance: "Tolerância de 0 a 5000 m.",
                       summary: "até %{zone} · tolerância %{m} m", directions: { towards: "Chegando", away_from: "Se afastando", stationary: "Parado", arrived: "Na zona" } },
          en: { title: "Proximity", description: "How far someone is from a zone (home, work) and whether they're getting closer or moving away.",
                "form.source" => "Who is tracked", "form.zone" => "Zone", "form.tolerance_m" => "Tolerance (m)", "form.unit" => "Unit",
                "hint.tolerance_m" => "Moved less than this between two readings: the direction doesn't change.",
                pick: "Choose who is tracked (with a location) and the zone.", tolerance: "Tolerance from 0 to 5000 m.",
                summary: "to %{zone} · tolerance %{m} m", directions: { towards: "Getting closer", away_from: "Moving away", stationary: "Stationary", arrived: "In the zone" } },
          es: { title: "Proximidad", description: "Qué tan lejos está alguien de una zona (casa, trabajo) y si se acerca o se aleja.",
                "form.source" => "Quién es rastreado", "form.zone" => "Zona", "form.tolerance_m" => "Tolerancia (m)", "form.unit" => "Unidad",
                "hint.tolerance_m" => "Se movió menos que esto entre dos lecturas: la dirección no cambia.",
                pick: "Elige quién es rastreado (con ubicación) y la zona.", tolerance: "Tolerancia de 0 a 5000 m.",
                summary: "hasta %{zone} · tolerancia %{m} m", directions: { towards: "Acercándose", away_from: "Alejándose", stationary: "Quieto", arrived: "En la zona" } }

    def self.located?(point) = point.attrs.to_h.key?("latitude")

    def self.form_spec
      [ [ :source, :point, { index: 0, filter: ->(p) { located?(p) } } ], [ :zone, :point, { index: 1, filter: ->(p) { p.helper == "zone" } } ],
        [ :tolerance_m, :number, { value: ->(p) { p.address["tolerance_m"] || 50 } } ],
        [ :unit, :select, { choices: -> { { "m" => "m", "km" => "km" } }, value: ->(p) { p.unit.presence || "m" } } ] ]
    end

    def self.assign(point, form)
      a = point.address
      ids = %w[source zone].each_with_index.map { |k, i| form[k].presence || a.dig("sources", i) }
      tracked, zone = ids.map { |id| point.site.points.find_by(id: id) }
      return point.errors.add(:base, text(:pick)) unless tracked && located?(tracked) && zone&.helper == "zone"

      tol = (form.key?("tolerance_m") ? number(form["tolerance_m"]) : a["tolerance_m"]) || 50
      point.data_type = "decimal"
      point.writable = false
      point.unit = (form["unit"] || point.unit).presence_in(%w[m km]) || "m"
      point.device_class = "distance"
      point.address = a.merge("sources" => ids, "tolerance_m" => tol)
      point.errors.add(:base, text(:tolerance)) unless tol.between?(0, 5000)
    end

    def self.sourced? = true

    def self.refresh!(point)
      tracked, zone = point.address["sources"].map { |id| point.site.points.find_by(id: id) }
      lat, lon = %w[latitude longitude].map { |k| Float(tracked&.attrs.to_h[k].to_s, exception: false) }
      center = zone && Zone.center(zone)
      return point.report!(point.value, quality: "unavailable") unless lat && lon && center

      meters = [ People.distance(lat, lon, *center) - Zone.radius(zone), 0 ].max
      last = state(point)["meters"]
      direction = if meters.zero? then "arrived"
      elsif last.nil? || (meters - last).abs < point.address["tolerance_m"].to_f then "stationary"
      else meters < last ? "towards" : "away_from"
      end
      # Parado não troca a referência: passos pequenos somados acabam contando.
      save_state!(point, { "meters" => meters }) unless direction == "stationary" && last
      point.report_attrs!(point.attrs.to_h.merge("direction" => direction, "in_zone" => meters.zero?, "zone" => zone.name))
      point.report!((point.unit == "km" ? meters / 1000.0 : meters).round(point.unit == "km" ? 2 : 0))
    end

    def self.value_text(point) = (d = point.attrs.to_h["direction"]).present? ? "#{point.value} #{point.unit} · #{text("directions.#{d}")}" : nil

    def self.summary(point)
      zone = point.site.points.find_by(id: point.address.dig("sources", 1))
      text(:summary, zone: zone&.name || "—", m: point.address["tolerance_m"].to_i)
    end
  end
end
