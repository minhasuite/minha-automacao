module Integrations
  # resto2 (grupo 9 #16; o `androidtv_remote` do HA): Google TV e Android TV
  # pelo protocolo do controle do app Google TV (AndroidTvRemote), sem ADB nem
  # modo desenvolvedor. Pareia com o código que a TV mostra: o primeiro
  # Continuar abre o pareamento (PendingPairing) e o segundo leva o código.
  # Ponto de mídia (liga, desliga, volume, mídia, abrir app/link) e ponto de
  # controle remoto com as teclas (setas, OK, voltar, início…).
  class AndroidtvRemotePlugin < SchemaPlugin
    describe key: "androidtv_remote", title: "Android TV Remote", icon: "desktop-computer",
             description: "Google TV e Android TV pelo protocolo do controle do app Google TV: liga, desliga, volume, mídia, teclas do controle e abrir app. Pareia com o código que aparece na TV."
    texts "pt-BR" => { fields: { code: "Código que aparece na TV" }, hints: { code: "6 letras e números; a TV mostra depois do primeiro Continuar" },
                       points: { media: "TV", remote: "Controle" },
                       need_code: "A TV está mostrando um código: digite em \"Código que aparece na TV\" e continue.",
                       wrong_code: "O código não confere com o da TV. Confira e tente de novo.", expired: "O pareamento expirou. Deixe o código vazio e continue para a TV mostrar outro.",
                       failed: "Não deu para falar com a TV: %{error}" },
          en: { title: "Android TV Remote", description: "Google TV and Android TV through the Google TV app's remote protocol: power, volume, media, remote keys and opening apps. Pairs with the code shown on the TV.",
                fields: { code: "Code shown on the TV" }, hints: { code: "6 letters and digits; the TV shows it after the first Continue" },
                points: { media: "TV", remote: "Remote" },
                need_code: "The TV is showing a code: type it in \"Code shown on the TV\" and continue.",
                wrong_code: "The code doesn't match the TV's. Check it and try again.", expired: "Pairing expired. Leave the code empty and continue so the TV shows a new one.",
                failed: "Couldn't talk to the TV: %{error}" },
          es: { title: "Android TV Remote", description: "Google TV y Android TV con el protocolo del control de la app Google TV: encender, apagar, volumen, multimedia, teclas del control y abrir apps. Vincula con el código que aparece en la TV.",
                fields: { code: "Código que aparece en la TV" }, hints: { code: "6 letras y números; la TV lo muestra tras el primer Continuar" },
                points: { media: "TV", remote: "Control" },
                need_code: "La TV muestra un código: escríbelo en \"Código que aparece en la TV\" y continúa.",
                wrong_code: "El código no coincide con el de la TV. Revísalo e inténtalo de nuevo.", expired: "La vinculación expiró. Deja el código vacío y continúa para que la TV muestre otro.",
                failed: "No se pudo hablar con la TV: %{error}" }
    field :host, required: true
    field :port, :number, default: 6466
    field :code
    mdns "_androidtvremote2._tcp"

    SUPPORTS = %w[on off pause resume next previous volume_up volume_down mute play_media].freeze
    BUTTONS = %w[up down left right center back home menu play_pause channel_up channel_down guide settings input power].freeze
    # Comando de mídia → tecla (ligar/desligar por WAKEUP/SLEEP: não inverte se já estiver no estado).
    MEDIA_KEYS = { "on" => "wake", "off" => "sleep" }.freeze

    class << self
      def add_found(*) = nil # precisa do código da TV

      def login(integration, form)
        host = form[:host].to_s.strip.presence || integration.settings["host"]
        port = (form[:port].presence || conf(integration, :port)).to_i
        integration.settings = integration.settings.merge("host" => host, "port" => port, "account" => host)
        integration.credentials = integration.secrets.merge(AndroidTvRemote.certificate).to_json if integration.secrets["cert"].blank?
        integration.save!
        code = form[:code].to_s.strip
        if code.present?
          pairing = PendingPairing.take(integration.id) or return outcome(:connect, integration: integration, alert: text(:expired))
          unless pairing.finish!(code)
            PendingPairing.put(integration.id, pairing)
            return outcome(:connect, integration: integration, alert: text(:wrong_code))
          end
          integration.merge_secrets!("paired" => true)
        elsif !integration.secrets["paired"]
          PendingPairing.put(integration.id, AndroidTvRemote::Pairing.new(host, port + 1, integration.secrets))
          return outcome(:connect, integration: integration, alert: text(:need_code))
        end
        r = Integrations.sync!(integration)
        outcome(:found, integration: integration, notice: text(:read, n: r[:found]))
      rescue AndroidTvRemote::Error, Integrations::Error, *LanPlugin::NET_ERRORS => e
        outcome(:connect, integration: integration, alert: text(:failed, error: e.message))
      end

      def session(integration, &)
        AndroidTvRemote::Remote.open(conf(integration, :host), conf(integration, :port), integration.secrets, &)
      rescue AndroidTvRemote::Error, *LanPlugin::NET_ERRORS => e
        raise Integrations::Error, "Android TV: #{e.message}"
      end

      def entries(integration)
        s = session(integration) { |r| r.settle(0.5) }
        name = [ s["vendor"], s["model"] ].compact_blank.join(" ").presence || title
        [ entry(id: "atvremote:#{conf(integration, :host)}", name: name, manufacturer: s["vendor"].presence || title, model: s["model"], category: "Mídia", poll_s: 30,
                points: [ point("media", "media", history: "none", address: { "supports" => SUPPORTS }),
                          point("remote", "remote", history: "none", address: { "codes" => BUTTONS.index_with { |b| AndroidTvRemote::KEYS[b] }, "supports" => %w[send] }) ]) ]
      end

      def read(device)
        s = session(device.integration, &:settle)
        return { "media" => { "state" => "off" } } if s["on"] == false

        volume = (s["volume"].to_i * 100 / s["max"].to_i).round if s["max"].to_i.positive?
        { "media" => { "state" => "on", "volume" => volume, "muted" => s["muted"], "app" => s["app"] }.compact }
      end

      def command(point, command, value)
        session(point.device.integration) do |r|
          case command
          when "play_media" then r.launch(value.to_s)
          when "send" then r.key(AndroidTvRemote::KEYS.fetch(value.to_s) { raise Integrations::Error, "Android TV: tecla #{value}?" })
          else r.key(AndroidTvRemote::KEYS.fetch(MEDIA_KEYS.fetch(command, command)))
          end
          r.settle(0.3) # lê o que a TV ainda manda: fechar com dado por ler derruba a conexão (RST) e a tecla se perde
        end
      end
    end
  end
end
