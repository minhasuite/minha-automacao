module Integrations
  # App do celular (F7, G17), como o mobile_app do HA: cada celular com o app
  # vira um aparelho virtual do local, da pessoa que entrou nele, com os
  # sensores que ela ligou no app (bateria, carregando, Wi-Fi e presença em
  # casa/fora pela localização). O app registra o aparelho
  # (`POST /api/v1/sites/:id/mobile_devices`) e manda as leituras
  # (`POST /api/v1/mobile_devices/:id/sensors`); daí em diante são pontos como
  # os outros (alertas, automações, painéis). Sensor novo = uma entrada em
  # `SENSORS` (campo → atributos do ponto, leitura e atributos extras) e o app
  # mandar o campo; nada muda no controller.
  class MobileAppPlugin < Plugin
    describe key: "mobile_app", title: "App do celular", icon: "device-mobile",
             description: "Bateria, carregando, Wi-Fi e presença (em casa ou fora) de cada celular com o app, como pontos."

    HOME_RADIUS_M = 150
    HOME = "Em casa".freeze
    AWAY = "Fora".freeze

    SENSORS = {
      "battery" => { name: "Bateria", capability: "measure", unit: "%", device_class: "battery",
                     read: ->(v, _i) { Float(v.to_s, exception: false)&.round&.clamp(0, 100) } },
      "charging" => { name: "Carregando", capability: "onoff", device_class: "battery_charging", read_only: true,
                      read: ->(v, _i) { ActiveModel::Type::Boolean.new.cast(v) } },
      "wifi" => { name: "Wi-Fi", capability: "text", device_class: "wifi_ssid", read: ->(v, _i) { v.to_s.delete('"').strip.first(64) } },
      "location" => { name: "Presença", capability: "enum", options: [ HOME, AWAY ], device_class: "location",
                      read: ->(v, i) { MobileAppPlugin.presence(i, v) }, attrs: ->(v, i) { MobileAppPlugin.location_attrs(i, v) } }
    }.freeze

    def self.setup(site, form)
      integration = site.integrations.find_by(driver: driver) || new_integration(site, poll_s: 0)
      configure(integration, form)
      outcome(:index, notice: "App do celular pronto. No celular: instale o app, entre e ligue os sensores em Mais → Sensores do celular.")
    end

    def self.login(integration, form)
      configure(integration, form)
      outcome(:index, notice: "App do celular atualizado.")
    end

    def self.configure(integration, form)
      radius = form[:home_radius_m].to_s.to_i
      keep = form.key?(:location_keep_h) ? form[:location_keep_h].to_s.to_i.clamp(0, KEEP_MAX_H) : integration.settings.fetch("location_keep_h", KEEP_H)
      integration.settings = integration.settings.merge("account" => "Celulares com o app", "home_radius_m" => radius.between?(30, 5000) ? radius : HOME_RADIUS_M,
                                                        "location_keep_h" => keep)
      integration.save!
    end

    # Privacidade (Pacote 3): a coordenada exata fica só aqui, nos atributos
    # do ponto "Presença" (sem histórico), e some depois de `location_keep_h`
    # horas sem leitura nova (0 = só a zona e a distância ficam). A pessoa e a
    # zona guardam só o nome da zona.
    KEEP_H = 24
    KEEP_MAX_H = 24 * 30
    PRECISE = %w[latitude longitude accuracy].freeze

    def self.tick(_now)
      ActsAsTenant.without_tenant do
        Integration.where(driver: driver).includes(:tenant).find_each do |i|
          ActsAsTenant.with_tenant(i.tenant) { forget_old_locations!(i) }
        end
      end
    end

    def self.forget_old_locations!(integration)
      keep = integration.settings.fetch("location_keep_h", KEEP_H).to_i
      Point.where(device_id: integration.site.devices.where(integration_id: integration.id).select(:id))
           .where("points.attrs ? 'latitude'").where(reported_at: ...(Time.current - keep.hours)).find_each do |p|
        p.update_column(:attrs, p.attrs.except(*PRECISE)) # rubocop:disable Rails/SkipsModelValidations
      end
    end

    # Sem varredura: os celulares é que mandam as leituras.
    def self.custom_sync? = true

    def self.sync!(integration)
      integration.ok!
      { found: integration.site.devices.where(integration_id: integration.id).count, fresh: 0, removed: 0, keys: 0 }
    end

    def self.integration_for(site)
      site.integrations.find_by(driver: driver) || new_integration(site, poll_s: 0, settings: { "account" => "Celulares com o app" }).tap(&:save!)
    end

    # Aparelho da pessoa neste celular (`install_id` gerado pelo app). Um por
    # pessoa e celular: outra conta no mesmo celular ganha o seu.
    def self.register!(site, user, install_id:, name:, model: nil, platform: nil)
      integration = integration_for(site)
      device = site.devices.find_or_initialize_by(driver: "virtual", external_id: "mobile_app:#{user.id}:#{install_id}")
      device.update!(name: name, manufacturer: title, model: model.presence, integration: integration, last_seen_at: Time.current,
                     address: device.address.to_h.merge("user_id" => user.id, "platform" => platform.presence).compact)
      device
    end

    def self.mobile?(device) = device.external_id.to_s.start_with?("mobile_app:")

    # Grava os campos que vieram (os outros ficam como estão).
    def self.report!(device, values)
      integration = device.integration || integration_for(device.site)
      SENSORS.each do |field, s|
        next unless values.key?(field)

        value = s[:read].call(values[field], integration)
        next if value.nil?

        point = point_for(device, field, s)
        point.report!(value)
        point.report_attrs!(s[:attrs].call(values[field], integration)) if s[:attrs]
      end
      device.update_columns(last_seen_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      integration.ok!
    end

    def self.point_for(device, field, s)
      device.points.find_by("address->>'field' = ?", field)&.tap { |p| p.update!(device_class: s[:device_class]) if p.device_class.nil? && s[:device_class] } ||
        device.points.create!(site: device.site, name: s[:name], capability: s[:capability], unit: s[:unit], device_class: s[:device_class],
                              options: s[:options] || [], history: "on_change", address: { "field" => field },
                              key: Integrations.unique_key(device.site, device, s[:name])).tap { |p| p.update!(writable: false) if s[:read_only] }
    end

    # "Em casa" quando a distância até o local, descontada a imprecisão do GPS,
    # cabe no raio (o mesmo critério das zonas do HA). nil = sem coordenadas.
    def self.presence(integration, loc)
      d = distance_to_site(integration, loc) or return
      radius = (integration.settings["home_radius_m"] || HOME_RADIUS_M).to_f
      d - accuracy(loc) <= radius ? HOME : AWAY
    end

    def self.location_attrs(integration, loc)
      lat, lon = coords(loc)
      zone = lat && People.zone_at(People.zones(integration.site), lat, lon, accuracy(loc))
      precise = integration.settings.fetch("location_keep_h", KEEP_H).to_i.positive?
      { "latitude" => (lat if precise), "longitude" => (lon if precise), "accuracy" => (accuracy(loc).round if precise),
        "distance_m" => distance_to_site(integration, loc)&.round, "zone" => zone&.name || (AWAY if lat) }.compact
    end

    def self.coords(loc)
      loc = loc.to_h
      lat = Float(loc["latitude"].to_s, exception: false)
      lon = Float(loc["longitude"].to_s, exception: false)
      [ lat, lon ] if lat&.between?(-90, 90) && lon&.between?(-180, 180)
    end

    def self.accuracy(loc) = Float(loc.to_h["accuracy"].to_s, exception: false).to_f.clamp(0, 1000)

    def self.distance_to_site(integration, loc)
      site = integration.site
      lat, lon = coords(loc)
      return unless lat && site.latitude && site.longitude

      haversine(lat, lon, site.latitude.to_f, site.longitude.to_f)
    end

    def self.haversine(lat1, lon1, lat2, lon2)
      rad = Math::PI / 180
      a = (Math.sin((lat2 - lat1) * rad / 2)**2) + (Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * (Math.sin((lon2 - lon1) * rad / 2)**2))
      2 * 6_371_000 * Math.asin(Math.sqrt(a))
    end
  end
end
