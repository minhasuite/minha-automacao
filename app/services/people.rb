# Pessoas, zonas e presença (Pacote 3), como o `person` e o `zone` do HA.
#
# Pessoa e zona são helpers (HelperTypes::Person e HelperTypes::Zone): por
# serem pontos, gatilho "Ponto mudou", painéis, histórico e API já servem.
# A pessoa junta várias fontes de rastreio (pontos de outros aparelhos) em
# ordem de prioridade; cada fonte é lida por um rastreador registrado em
# `TRACKERS` (GPS do app, Wi-Fi de casa, conectado na rede). Rastreador novo
# = classe com `applies?(ponto)`, `label` e `zone(ponto, pessoa, zonas)` +
# nome em `TRACKERS`; nada muda na pessoa nem nas telas.
module People
  AWAY = "Fora".freeze
  # Ordem = a primeira que se aplica ao ponto lê ele.
  TRACKERS = %w[Gps WifiSsid Face Room Connected].freeze

  module_function

  def trackers = TRACKERS.map { |n| Trackers.const_get(n) }
  def tracker_for(point) = trackers.find { |t| t.applies?(point) }

  def persons(site) = site.points.where(helper: "person").ordered
  def zones(site) = site.points.where(helper: "zone").includes(:site).to_a

  # Pontos que servem de fonte (algum rastreador lê), menos os helpers.
  def trackable(site) = site.points.where(helper: nil).includes(:device).ordered.select { |p| tracker_for(p) }

  # Zona onde a coordenada cai: a de menor raio que a contém, descontada a
  # imprecisão do GPS (o mesmo critério do HA). nil = nenhuma.
  def zone_at(zones, lat, lon, accuracy = 0)
    zones.filter_map do |z|
      c = HelperTypes::Zone.center(z) or next
      d = distance(lat, lon, *c)
      [ z, HelperTypes::Zone.radius(z) ] if d - accuracy.to_f <= HelperTypes::Zone.radius(z)
    end.min_by(&:last)&.first
  end

  def distance(lat1, lon1, lat2, lon2)
    rad = Math::PI / 180
    a = (Math.sin((lat2 - lat1) * rad / 2)**2) + (Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * (Math.sin((lon2 - lon1) * rad / 2)**2))
    2 * 6_371_000 * Math.asin(Math.sqrt(a))
  end

  # Resumo das pessoas para o widget e a API.
  def summary(site)
    persons(site).map do |p|
      { "id" => p.id, "name" => p.name, "zone" => p.value, "home" => HelperTypes::Person.home?(p), "since" => p.changed_at&.iso8601,
        "source" => p.attrs.to_h["source"], "user_id" => p.address["user_id"], "quality" => p.quality }
    end
  end

  module Trackers
    class Base
      extend PluginTexts
      translates :label

      class << self
        def describe(label:) = (@label = label)
        def applies?(_point) = false
        # → nome da zona, People::AWAY ou nil (sem opinião agora).
        def zone(_point, _person, _zones) = nil
      end
    end

    # Coordenadas nos atributos (o "Presença" do app do celular ou qualquer
    # ponto que traga latitude e longitude): a zona é a das coordenadas. O
    # app do celular já manda a zona resolvida (`zone`), que vale mesmo
    # depois que a coordenada exata some pela retenção.
    class Gps < Base
      describe label: "Localização (GPS)"
      texts en: { label: "Location (GPS)" }, es: { label: "Ubicación (GPS)" }

      def self.applies?(point) = point.attrs.to_h.key?("latitude") || point.device_class == "location"

      def self.zone(point, _person, zones)
        a = point.attrs.to_h
        lat = Float(a["latitude"].to_s, exception: false)
        lon = Float(a["longitude"].to_s, exception: false)
        return People.zone_at(zones, lat, lon, a["accuracy"])&.name || AWAY if lat && lon

        a["zone"] if a["zone"] == AWAY || zones.any? { |z| z.name == a["zone"] }
      end
    end

    # Nome do Wi-Fi: numa das redes de casa da pessoa = em casa. Fora delas não
    # diz nada (pode estar só no 4G dentro de casa).
    class WifiSsid < Base
      describe label: "Wi-Fi de casa"
      texts en: { label: "Home Wi-Fi" }, es: { label: "Wi-Fi de casa" }

      def self.applies?(point) = point.device_class == "wifi_ssid"

      def self.zone(point, person, zones)
        ssids = HelperTypes::Person.home_ssids(person)
        return unless ssids.include?(point.value.to_s.strip.downcase)

        HelperTypes::Zone.home_of(zones)&.name
      end
    end

    # Rosto reconhecido na câmera (Double Take): visto há pouco = em casa;
    # não visto não quer dizer fora (sem opinião).
    class Face < Base
      describe label: "Rosto na câmera"
      texts en: { label: "Face on camera" }, es: { label: "Rostro en la cámara" }

      def self.applies?(point) = point.address.to_h["tracker"] == "face" && point.bool?
      def self.zone(point, _person, zones) = (HelperTypes::Zone.home_of(zones)&.name if point.value == true)
    end

    # Cômodo atual por Bluetooth (ESPresense): num cômodo = em casa; fora de
    # alcance não quer dizer fora (sem opinião).
    class Room < Base
      describe label: "Cômodo (Bluetooth)"
      texts en: { label: "Room (Bluetooth)" }, es: { label: "Cuarto (Bluetooth)" }

      def self.applies?(point) = point.address.to_h["tracker"] == "room"

      def self.zone(point, _person, zones)
        room = point.value.to_s
        HelperTypes::Zone.home_of(zones)&.name if room.present? && room != Espresense::AWAY
      end
    end

    # Conectado na rede (rastreador de rede, ping): ligado = em casa; desligado = fora.
    class Connected < Base
      describe label: "Conectado na rede"
      texts en: { label: "Connected to the network" }, es: { label: "Conectado a la red" }

      def self.applies?(point) = point.device_class.in?(%w[presence connectivity]) && point.bool?

      def self.zone(point, _person, zones)
        return HelperTypes::Zone.home_of(zones)&.name if point.value == true

        AWAY if point.value == false
      end
    end
  end
end
