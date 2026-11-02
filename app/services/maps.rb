# Mapa (paridade com o HA): pessoas e zonas do local (helpers `person` e
# `zone`) e o trajeto do dia de quem tem o histórico de localização (atributo
# `track` do ponto que dá a coordenada, ex. o "Presença" do app do celular).
# Onde as pessoas estão é dado sensível: só morador para cima vê (visitante
# e operador, não), na tela, no widget e na API.
module Maps
  MIN_ROLE = "resident".freeze

  module_function

  def roles = SiteMembership::ROLES.drop(SiteMembership::ROLES.index(MIN_ROLE))
  def allowed_role?(role) = roles.include?(role.to_s)
  def allowed?(user) = user.admin? || SiteMembership.active.where(user_id: user.id, role: roles).exists?

  # → {zones:, people:, center:}. Pessoa sem coordenada exata fica no centro
  # da zona em que está (`precise: false`); fora de zona e sem coordenada, sem posição.
  def data(site, track: true)
    zones = People.zones(site).filter_map do |z|
      lat, lon = HelperTypes::Zone.center(z)
      next unless lat && lon

      { "id" => z.id, "name" => z.name, "lat" => lat, "lon" => lon, "radius" => HelperTypes::Zone.radius(z).round,
        "home" => HelperTypes::Zone.home?(z), "count" => z.value.to_i }
    end
    people = People.persons(site).map { |p| person(p, zones, track) }
    { "zones" => zones, "people" => people, "center" => center(site, zones, people),
      "texts" => { "people" => I18n.t("maps.js.people"), "no_reading" => I18n.t("maps.no_reading"), "approx" => I18n.t("maps.js.approx") } }
  end

  def person(p, zones, track)
    a = HelperTypes::Person.sources(p).find { |s| s.quality == "good" && s.attrs.to_h["latitude"] }&.attrs.to_h || {}
    zone = zones.find { |z| z["name"] == p.value }
    lat = a["latitude"] || zone&.dig("lat")
    lon = a["longitude"] || zone&.dig("lon")
    { "id" => p.id, "name" => p.name, "initials" => p.name.to_s.split.first(2).map { |s| s[0] }.join.upcase, "zone" => p.value,
      "home" => HelperTypes::Person.home?(p), "since" => p.changed_at&.iso8601, "quality" => p.quality,
      "lat" => lat, "lon" => lon, "accuracy" => a["accuracy"], "precise" => a["latitude"].present?,
      "track" => (track ? Array(a["track"]).map { |la, lo, t| [ la, lo, Time.zone.at(t.to_i).iso8601 ] } : []) }
  end

  def center(site, zones, people)
    return [ site.latitude.to_f, site.longitude.to_f ] if site.latitude && site.longitude

    first = zones.first || people.find { |p| p["lat"] }
    first && [ first["lat"], first["lon"] ]
  end
end
