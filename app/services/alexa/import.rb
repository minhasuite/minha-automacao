module Alexa
  # Conta da Alexa a partir dos cookies de uma sessão já logada (o login
  # próprio fica em Alexa::Auth; este é o caminho de colar cookies: o arquivo
  # `.storage/alexa_media.<email>.cookies` do HA, formato alexapy, ou um
  # objeto {nome => valor}) e descoberta das Echo, Fire TV e grupos (só leitura da lista).
  # Idempotente: integração por local, Echo pelo número de série.
  module Import
    AREA = "Importados do HA".freeze
    # Echo, Echo Show e Echo Studio: falam (ponto `speaker`, o canal dos avisos).
    SPEAKERS = %w[ECHO KNIGHT ROOK].freeze
    # Fire TV e grupo de alto-falantes (WHA: "Todo lugar", "Terraço" do app Alexa): só a mídia
    # (os pontos de Alexa::State), como o media_player do alexa_media; aviso continua só nas Echo.
    MEDIA_ONLY = %w[FIRE_TV WHA].freeze
    FAMILIES = (SPEAKERS + MEDIA_ONLY).freeze
    STATES = { true => "online", false => "offline" }.freeze

    module_function

    def cookies_from(data)
      data = JSON.parse(data) if data.is_a?(String)
      list = data.is_a?(Hash) && data["cookies"].is_a?(Array) ? data["cookies"] : nil
      return data.to_h { |k, v| [ k.to_s, v.to_s ] } unless list

      list.select { |c| c["domain"].to_s.delete_prefix(".") == Client::HOST.delete_prefix("alexa.") }.to_h { |c| [ c["name"], c["value"].to_s ] }
    end

    def call(site, data, name: "Alexa")
      integration = site.integrations.find_or_initialize_by(driver: "alexa")
      integration.name = name if integration.new_record?
      integration.settings = { "host" => Client::HOST }.merge(integration.settings).except("login")
      integration.credentials = { "cookies" => cookies_from(data) }.merge(integration.secrets.slice("serial")).to_json
      integration.save!
      discover!(integration)
    end

    # Lê as Echo da conta e cria/atualiza dispositivo e ponto `speaker`.
    def discover!(integration, client: Drivers::Alexa.client_for(integration))
      list = client.devices.select { |d| FAMILIES.include?(d["deviceFamily"]) }
      site = integration.site
      area = site.areas.find_or_create_by!(name: AREA) unless integration.settings["login"] == "app" # login próprio: Echo nova sem área
      count = { devices: 0, points: 0 }
      list.each do |d|
        device = site.devices.find_or_initialize_by(driver: "alexa", external_id: d["serialNumber"])
        count[:devices] += 1 if device.new_record?
        device.assign_attributes(name: (device.name.presence || d["accountName"]), area: device.area || area, integration: integration,
                                 model: d["deviceType"], status: STATES.fetch(d["online"] == true),
                                 address: { "device_type" => d["deviceType"], "customer_id" => d["deviceOwnerCustomerId"] })
        device.save!
        next Alexa::State.points_for(device) if MEDIA_ONLY.include?(d["deviceFamily"])

        point = device.points.find_by(capability: "speaker")
        unless point
          point = device.points.create!(site: site, name: "Falar", capability: "speaker", history: "none")
          count[:points] += 1
        end
        point.report!(STATES.fetch(d["online"] == true))
      end
      integration.ok!
      count.merge(echos: list.count { |d| SPEAKERS.include?(d["deviceFamily"]) })
    rescue Client::Error => e
      integration.error!(e.message)
      raise
    end
  end
end
