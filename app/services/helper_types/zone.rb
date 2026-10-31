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
        point.errors.add(:base, "Informe latitude e longitude (ou marque \"É a casa\").") unless lat&.between?(-90, 90) && lon&.between?(-180, 180)
        a = a.merge("latitude" => lat, "longitude" => lon)
      end
      point.errors.add(:base, "O raio vai de 20 m a 50 km.") unless radius.between?(20, 50_000)
      others = point.site.points.where(helper: key).where.not(id: point.id)
      point.errors.add(:base, "Já há uma zona da casa neste local.") if home && others.exists?([ "address->>'home' = 'true'" ])
      point.errors.add(:name, "já é de outra zona") if point.site.points.where(helper: key).where.not(id: point.id).exists?(name: point.name)
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
      [ ("casa (local)" if home?(point)), "raio #{radius(point).round} m", (c ? c.map { |x| x.round(4) }.join(", ") : "sem coordenadas no local") ].compact.join(" · ")
    end
  end
end
