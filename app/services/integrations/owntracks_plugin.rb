module Integrations
  # OwnTracks Recorder (app do catálogo): a última posição de cada celular
  # com o app OwnTracks (`/api/0/last`). Cada usuário/aparelho vira um
  # aparelho com o ponto "Presença" (valor = nome da zona ou "Fora") e a
  # bateria; o rastreador People::Trackers::Gps lê a zona.
  #
  # Privacidade (as mesmas regras do app do celular): a coordenada exata fica
  # só nos atributos do "Presença" (sem histórico), e só se
  # `location_keep_h` > 0; some `location_keep_h` horas depois da posição
  # (`tick`). O valor e o histórico guardam só o nome da zona.
  class OwntracksPlugin < SchemaPlugin
    describe key: "owntracks", title: "OwnTracks", icon: "location-marker",
             description: "Localização dos celulares pelo OwnTracks Recorder da casa: a zona de cada pessoa (Casa, Trabalho, Fora) para presença e automações."
    texts "pt-BR" => { fields: { location_keep_h: "Guardar a coordenada exata por (horas)" },
                       hints: { url: "http://192.168.0.10:8083", location_keep_h: "0 = só a zona" },
                       points: { location: "Presença" }, none: "O Recorder ainda não recebeu nenhuma posição." },
          en: { title: "OwnTracks", description: "Phone locations from your OwnTracks Recorder: each person's zone (Home, Work, Away) for presence and automations.",
                fields: { location_keep_h: "Keep the exact coordinate for (hours)" }, hints: { url: "http://192.168.0.10:8083", location_keep_h: "0 = zone only" },
                points: { location: "Presence" }, none: "The Recorder hasn't received any position yet." },
          es: { title: "OwnTracks", description: "Ubicación de los celulares por el OwnTracks Recorder de casa: la zona de cada persona (Casa, Trabajo, Fuera) para presencia y automatizaciones.",
                fields: { location_keep_h: "Guardar la coordenada exacta por (horas)" }, hints: { url: "http://192.168.0.10:8083", location_keep_h: "0 = solo la zona" },
                points: { location: "Presencia" }, none: "El Recorder aún no recibió ninguna posición." }
    field :url, :url, required: true
    field :username
    field :password, secret: true
    field :location_keep_h, :number, default: 24

    PRECISE = MobileAppPlugin::PRECISE

    class << self
      def last(integration)
        base = LanHttp.base(conf(integration, :url)) or raise(Integrations::Error, field_label(:url))
        user = conf(integration, :username)
        headers = user.present? ? { "Authorization" => "Basic #{Base64.strict_encode64("#{user}:#{conf(integration, :password)}")}" } : {}
        list = LanHttp.get("#{base}/api/0/last", headers: headers)
        list = list["data"] if list.is_a?(Hash)
        Array(list).select { |l| l.is_a?(Hash) && l["username"].present? }
      end

      def ref(loc) = [ loc["username"], loc["device"] ].compact_blank.join("/")

      def entries(integration)
        list = last(integration).presence or raise(Integrations::Error, text(:none))
        list.map do |l|
          entry(id: "owntracks:#{ref(l)}", name: [ l["username"], l["device"] ].compact_blank.join(" · "), manufacturer: "OwnTracks", poll_s: 60,
                address: { "ref" => ref(l) },
                points: [ point("location", "text", device_class: "location", icon: "location-marker"),
                          point("battery", unit: "%", state_class: "measurement", device_class: "battery") ])
        end
      end

      def keep_h(integration) = conf(integration, :location_keep_h).to_i.clamp(0, MobileAppPlugin::KEEP_MAX_H)

      # Zona da posição (a de menor raio que contém, como no app) e os atributos permitidos.
      def place(device, loc)
        lat = Float(loc["lat"].to_s, exception: false)
        lon = Float(loc["lon"].to_s, exception: false)
        return unless lat&.between?(-90, 90) && lon&.between?(-180, 180)

        zone = People.zone_at(People.zones(device.site), lat, lon, loc["acc"].to_f)&.name || People::AWAY
        precise = keep_h(device.integration).positive?
        attrs = { "zone" => zone, "at" => loc["tst"].to_i, "latitude" => (lat if precise), "longitude" => (lon if precise),
                  "accuracy" => (loc["acc"].to_f.round if precise) }.compact
        [ zone, attrs ]
      end

      # Uma leitura do Recorder para todos os aparelhos da integração.
      def poll(device)
        loc = last(device.integration).find { |l| ref(l) == device.address["ref"] }
        device.update_columns(status: "online", last_seen_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        return unless loc

        zone, attrs = place(device, loc)
        device.points.reject(&:disabled).each do |p|
          case p.address["field"]
          when "battery" then p.report!(loc["batt"].to_f) if loc["batt"]
          when "location"
            next unless zone

            p.report!(zone)
            p.report_attrs!(p.attrs.to_h.except(*PRECISE).merge(attrs)) if attrs["at"] != p.attrs.to_h["at"]
          end
        end
      end

      # A cada minuto: apaga a coordenada exata mais velha que `location_keep_h`.
      def tick(_now)
        ActsAsTenant.without_tenant do
          Integration.where(driver: driver).includes(:tenant).find_each do |i|
            ActsAsTenant.with_tenant(i.tenant) { forget_old_locations!(i) }
          end
        end
      end

      def forget_old_locations!(integration)
        limit = (Time.current - keep_h(integration).hours).to_i
        Point.where(device_id: integration.devices.select(:id)).where("points.attrs ? 'latitude'").find_each do |p|
          p.update_column(:attrs, p.attrs.except(*PRECISE)) if p.attrs["at"].to_i <= limit # rubocop:disable Rails/SkipsModelValidations
        end
      end
    end
  end
end
