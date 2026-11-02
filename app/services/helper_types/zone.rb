module HelperTypes
  # Zona (zone do HA): um círculo (centro e raio). A casa é a zona com
  # `home` = o local com as coordenadas do cadastro. O valor é quantas
  # pessoas estão nela agora: "o primeiro chegou" e "todos saíram" são essa
  # contagem passando de 0 para 1 e de volta (gatilho "Presença na zona").
  class Zone < Plugin
    DEFAULT_RADIUS = 150
    HOME_NAME = "Casa".freeze

    describe key: "zone", title: "Zona", icon: "location-marker", capability: "counter",
             description: "Um lugar no mapa (casa, trabalho, escola) com raio. Conta quem está nele."
    fields %i[latitude longitude radius_m home]
    texts "pt-BR" => { coords: "Informe latitude e longitude (ou marque \"É a casa\").", radius: "O raio vai de 20 m a 50 km.",
                       home_taken: "Já há uma zona da casa neste local.", name: "já é de outra zona", home: "casa (local)",
                       radius_m: "raio %{m} m", no_coords: "sem coordenadas no local" },
          en: { title: "Zone", description: "A place on the map (home, work, school) with a radius. Counts who's in it.",
                coords: "Enter latitude and longitude (or check \"This is home\").", radius: "The radius goes from 20 m to 50 km.",
                home_taken: "This place already has a home zone.", name: "is already used by another zone", home: "home (place)",
                radius_m: "%{m} m radius", no_coords: "no coordinates on the place" },
          es: { title: "Zona", description: "Un lugar en el mapa (casa, trabajo, escuela) con un radio. Cuenta quién está en él.",
                coords: "Indica latitud y longitud (o marca \"Es la casa\").", radius: "El radio va de 20 m a 50 km.",
                home_taken: "Ya hay una zona de la casa en este lugar.", name: "ya es de otra zona", home: "casa (lugar)",
                radius_m: "radio de %{m} m", no_coords: "el lugar no tiene coordenadas" }

    def self.assign(point, form)
      point.writable = false
      point.data_type = "integer"
      point.unit = "pessoas"
      home = ActiveModel::Type::Boolean.new.cast(form["home"]) || false
      radius = (number(form["radius_m"]) || DEFAULT_RADIUS).round
      a = point.address.merge("home" => home, "radius_m" => radius)
      unless home
        lat = number(form["latitude"])
        lon = number(form["longitude"])
        point.errors.add(:base, text(:coords)) unless lat&.between?(-90, 90) && lon&.between?(-180, 180)
        a = a.merge("latitude" => lat, "longitude" => lon)
      end
      point.errors.add(:base, text(:radius)) unless radius.between?(20, 50_000)
      others = point.site.points.where(helper: key).where.not(id: point.id)
      point.errors.add(:base, text(:home_taken)) if home && others.exists?([ "address->>'home' = 'true'" ])
      point.errors.add(:name, text(:name)) if point.site.points.where(helper: key).where.not(id: point.id).exists?(name: point.name)
      point.address = a
    end

    def self.sourced? = true
    def self.refresh!(point) = point.report!(People.persons(point.site).where(value: point.name).count)

    # Zona da casa do local, criada na primeira pessoa (raio do app do celular, se houver).
    def self.home(site)
      site.points.where(helper: key).find_by("address->>'home' = 'true'") || begin
        point = HelperTypes.build(site, self)
        radius = site.integrations.find_by(driver: "mobile_app")&.settings&.dig("home_radius_m")
        HelperTypes.save(point, { "name" => HOME_NAME, "home" => "1", "radius_m" => radius || DEFAULT_RADIUS }) && point
      end
    end

    def self.home?(point) = point.address["home"] == true
    def self.home_of(zones) = zones.find { |z| home?(z) }
    def self.radius(point) = point.address["radius_m"].to_f

    # [lat, lon] da zona (a casa usa a do local); nil = sem coordenadas.
    def self.center(point)
      if home?(point)
        s = point.site
        return s.latitude && s.longitude ? [ s.latitude.to_f, s.longitude.to_f ] : nil
      end
      [ point.address["latitude"], point.address["longitude"] ] if point.address["latitude"] && point.address["longitude"]
    end

    def self.summary(point)
      c = center(point)
      [ (text(:home) if home?(point)), text(:radius_m, m: radius(point).round), (c ? c.map { |x| x.round(4) }.join(", ") : text(:no_coords)) ].compact.join(" · ")
    end
  end
end
