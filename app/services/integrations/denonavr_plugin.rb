module Integrations
  # Receiver Denon/Marantz (catalogo): pela interface HTTP do receiver
  # (`formMainZone_MainZoneXmlStatusLite.xml` e `formiPhoneAppDirect.xml` com
  # os comandos do protocolo de controle: PWON, MV, MU, SI…). Zona principal
  # como player de mídia: liga, volume, mudo e entrada.
  class DenonavrPlugin < SchemaPlugin
    describe key: "denonavr", title: "Denon / Marantz AVR", icon: "volume-up",
             description: "Receivers Denon e Marantz na rede de casa: liga e desliga, volume, mudo e a entrada (TV, Blu-ray, streaming), como player de mídia."
    texts "pt-BR" => { hints: { port: "80 ou 8080 (modelos de 2016 em diante)" }, not_avr: "O endereço respondeu, mas não como um receiver Denon/Marantz." },
          en: { title: "Denon / Marantz AVR", description: "Denon and Marantz receivers on your home network: power, volume, mute and input (TV, Blu-ray, streaming), as a media player.",
                hints: { port: "80 or 8080 (2016 models onward)" }, not_avr: "The address answered, but not as a Denon/Marantz receiver." },
          es: { title: "Denon / Marantz AVR", description: "Receptores Denon y Marantz en la red de casa: encendido, volumen, silencio y la entrada (TV, Blu-ray, streaming), como reproductor.",
                hints: { port: "80 u 8080 (modelos de 2016 en adelante)" }, not_avr: "La dirección respondió, pero no como un receptor Denon/Marantz." }
    field :host, required: true
    field :port, :number, default: 80
    ssdp "urn:schemas-denon-com:device:ACT-Denon:1"

    SUPPORTS = %w[on off volume volume_up volume_down mute play_media].freeze
    CMDS = { "on" => "PWON", "off" => "PWSTANDBY", "volume_up" => "MVUP", "volume_down" => "MVDOWN" }.freeze

    class << self
      def base(device_or_integration)
        a = device_or_integration.is_a?(Device) ? device_or_integration.address : { "host" => conf(device_or_integration, :host), "port" => conf(device_or_integration, :port) }
        LanHttp.base("#{a['host']}:#{a['port']}")
      end

      def status(base)
        xml = LanHttp.get("#{base}/goform/formMainZone_MainZoneXmlStatusLite.xml", raw: true).to_s
        ->(name) { xml[%r{<#{name}>\s*<value>([^<]*)</value>}m, 1] }
      end

      def entries(integration)
        b = base(integration)
        st = status(b)
        raise Integrations::Error, text(:not_avr) if st.("Power").nil?

        name = begin
          LanHttp.get("#{b}/goform/formMainZone_MainZoneXml.xml", raw: true).to_s[%r{<FriendlyName>\s*<value>([^<]*)</value>}m, 1]
        rescue Integrations::Error
          nil
        end

        [ entry(id: "denonavr:#{conf(integration, :host)}", name: name.presence || title, category: "Mídia",
                address: { "host" => conf(integration, :host), "port" => conf(integration, :port).to_i }, poll_s: 30,
                points: [ point("media", "media", name: text("points.player"), history: "none", address: { "supports" => SUPPORTS }) ]) ]
      end

      def read(device)
        st = status(base(device))
        db = st.("MasterVolume").to_s
        volume = ((db.to_f + 80) * 100 / 80).round.clamp(0, 100) if db.match?(/\A-?[\d.]+\z/)
        { "media" => { "state" => st.("Power") == "ON" ? "on" : "off", "volume" => volume, "muted" => st.("Mute") == "on", "source" => st.("InputFuncSelect") }.compact }
      end

      def command(point, command, value)
        cmd = case command
        when "volume" then format("MV%02d", (value.to_f * 0.8).round.clamp(0, 80))
        when "mute" then value ? "MUON" : "MUOFF"
        when "play_media" then "SI#{value.to_s.upcase.delete(' ')}"
        else CMDS.fetch(command)
        end
        LanHttp.get("#{base(point.device)}/goform/formiPhoneAppDirect.xml?#{cmd}", raw: true)
      end
    end
  end
end
