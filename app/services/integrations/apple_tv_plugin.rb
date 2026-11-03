module Integrations
  # resto2 (grupo 9 #22; o `apple_tv` do HA): Apple TV (tvOS 15 ou mais) pelo
  # protocolo Companion (Companion::Client), em Ruby, sem pyatv. Pareia pelo
  # PIN de 4 dígitos que aparece na TV (o primeiro Continuar pede o PIN, o
  # segundo leva) e guarda o pareamento cifrado. Liga (acorda), desliga
  # (dorme), mídia, volume, abrir app pelo bundle id ou link, e as teclas do
  # controle. Estado: acordada ou dormindo. "O que está tocando" (MRP pelo
  # AirPlay 2) não entra: ver docs/catalogo.md.
  class AppleTvPlugin < SchemaPlugin
    describe key: "apple_tv", title: "Apple TV", icon: "desktop-computer",
             description: "Apple TV na rede de casa pelo protocolo do Controle Remoto do iPhone: liga, desliga, mídia, volume, teclas do controle e abrir app. Pareia com o PIN que aparece na TV."
    texts "pt-BR" => { fields: { pin: "PIN que aparece na Apple TV" }, hints: { pin: "4 dígitos; a TV mostra depois do primeiro Continuar" },
                       points: { media: "Apple TV", remote: "Controle" },
                       need_code: "A Apple TV está mostrando um PIN: digite em \"PIN que aparece na Apple TV\" e continue.",
                       expired: "O pareamento expirou. Deixe o PIN vazio e continue para a TV mostrar outro.", failed: "Não deu para falar com a Apple TV: %{error}" },
          en: { title: "Apple TV", description: "Apple TV on your home network through the iPhone Remote protocol: power, media, volume, remote keys and opening apps. Pairs with the PIN shown on the TV.",
                fields: { pin: "PIN shown on the Apple TV" }, hints: { pin: "4 digits; the TV shows it after the first Continue" },
                points: { media: "Apple TV", remote: "Remote" },
                need_code: "The Apple TV is showing a PIN: type it in \"PIN shown on the Apple TV\" and continue.",
                expired: "Pairing expired. Leave the PIN empty and continue so the TV shows a new one.", failed: "Couldn't talk to the Apple TV: %{error}" },
          es: { title: "Apple TV", description: "Apple TV en la red de casa con el protocolo del Control Remoto del iPhone: encender, apagar, multimedia, volumen, teclas del control y abrir apps. Vincula con el PIN que aparece en la TV.",
                fields: { pin: "PIN que aparece en el Apple TV" }, hints: { pin: "4 dígitos; la TV lo muestra tras el primer Continuar" },
                points: { media: "Apple TV", remote: "Control" },
                need_code: "El Apple TV muestra un PIN: escríbelo en \"PIN que aparece en el Apple TV\" y continúa.",
                expired: "La vinculación expiró. Deja el PIN vacío y continúa para que la TV muestre otro.", failed: "No se pudo hablar con el Apple TV: %{error}" }
    field :host, required: true
    field :port, :number, default: 49_153
    field :pin
    mdns "_companion-link._tcp"

    SUPPORTS = %w[on off pause resume next previous volume_up volume_down play_media].freeze
    BUTTONS = %w[up down left right select menu home play_pause channel_up channel_down guide page_up page_down screensaver siri].freeze
    ERRORS = [ Companion::Error, Hap::Error, *LanPlugin::NET_ERRORS ].freeze

    class << self
      def add_found(*) = nil # precisa do PIN

      def login(integration, form)
        host = form[:host].to_s.strip.presence || integration.settings["host"]
        port = (form[:port].presence || conf(integration, :port)).to_i
        integration.settings = integration.settings.merge("host" => host, "port" => port, "account" => host)
        integration.save!
        pin = form[:pin].to_s.strip
        if pin.present?
          client = PendingPairing.take(integration.id) or return outcome(:connect, integration: integration, alert: text(:expired))
          begin
            integration.merge_secrets!("pairing" => client.pair_finish!(client.pin_code(pin)).to_json)
          ensure
            client.close
          end
        elsif integration.secrets["pairing"].blank?
          client = Companion::Client.new(host, port)
          begin
            client.pair_start!
          rescue StandardError
            client.close
            raise
          end
          PendingPairing.put(integration.id, client)
          return outcome(:connect, integration: integration, alert: text(:need_code))
        end
        r = Integrations.sync!(integration)
        outcome(:found, integration: integration, notice: text(:read, n: r[:found]))
      rescue Integrations::Error, *ERRORS => e
        outcome(:connect, integration: integration, alert: text(:failed, error: e.message))
      end

      def pairing(integration) = JSON.parse(integration.secrets["pairing"].to_s.presence || "{}")

      def session(integration)
        Companion::Client.open(conf(integration, :host), conf(integration, :port), pairing(integration)) { |c| yield c.start! }
      rescue *ERRORS => e
        raise Integrations::Error, "Apple TV: #{e.message}"
      end

      def entries(integration)
        apps = session(integration) { |c| c.request("FetchLaunchableApplicationsEvent") }
        [ entry(id: "appletv:#{pairing(integration)['accessory_id']}", name: integration.name.presence || title, manufacturer: "Apple", model: "Apple TV",
                category: "Mídia", poll_s: 30,
                points: [ point("media", "media", history: "none", address: { "supports" => SUPPORTS, "apps" => apps.to_h.first(80).to_h }),
                          point("remote", "remote", history: "none", address: { "codes" => BUTTONS.index_with { |b| Companion::HID[b] }, "supports" => %w[send] }) ]) ]
      end

      def read(device)
        state = session(device.integration) { |c| c.request("FetchAttentionState")["state"] }
        { "media" => { "state" => state.to_i == Companion::ASLEEP ? "off" : "on" } }
      end

      def command(point, command, value)
        session(point.device.integration) do |c|
          case command
          when "on" then c.press("wake")
          when "off" then c.press("sleep")
          when "volume_up", "volume_down", "send" then c.press(command == "send" ? value : command)
          when "play_media" then c.request("_launchApp", value.to_s.include?("://") ? { "_urlS" => value.to_s } : { "_bundleID" => value.to_s })
          else c.request("_mcc", "_mcc" => Companion::MEDIA.fetch(command))
          end
        end
      end
    end
  end
end
