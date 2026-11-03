module Integrations
  # Sony Bravia (catalogo): TV Bravia pela API REST da Sony (JSON-RPC em
  # `/sony/<serviço>`) com a chave pré-compartilhada (PSK) da TV. Liga, desliga,
  # volume, mudo, entrada/app aberto e abrir um conteúdo pela URI.
  class BraviatvPlugin < SchemaPlugin
    describe key: "braviatv", title: "Sony Bravia TV", icon: "desktop-computer",
             description: "TVs Sony Bravia na rede de casa: liga e desliga, volume, mudo, a entrada ou o app aberto e trocar de entrada."
    texts "pt-BR" => { fields: { psk: "Chave pré-compartilhada (PSK)" },
                       note: "Na TV: Configurações → Rede → Configuração da rede doméstica → Controle IP: Autenticação \"Normal e chave pré-compartilhada\" e a chave aqui." },
          en: { title: "Sony Bravia TV", description: "Sony Bravia TVs on your home network: power, volume, mute, the open input or app, and switching inputs.",
                fields: { psk: "Pre-shared key (PSK)" },
                note: "On the TV: Settings → Network → Home network setup → IP control: Authentication \"Normal and Pre-Shared Key\" and the key here." },
          es: { title: "Sony Bravia TV", description: "Televisores Sony Bravia en la red de casa: encendido, volumen, silencio, la entrada o la app abierta y cambiar de entrada.",
                fields: { psk: "Clave precompartida (PSK)" },
                note: "En la TV: Configuración → Red → Configuración de red doméstica → Control IP: Autenticación \"Normal y clave precompartida\" y la clave aquí." }
    field :host, required: true
    field :psk, secret: true, required: true
    ssdp "urn:schemas-sony-com:service:ScalarWebAPI:1"
    SUPPORTS = %w[on off volume volume_up volume_down mute play_media].freeze

    class << self
      def rpc(integration, host, service, method, params = [], version: "1.0")
        r = LanHttp.post("http://#{host}/sony/#{service}", { method: method, params: params, id: 1, version: version }, headers: { "X-Auth-PSK" => conf(integration, :psk).to_s })
        if (err = r["error"])
          e = Integrations::Error.new("Bravia: #{err[1] || err[0]}")
          raise [ 401, 403 ].include?(err[0]) ? Integrations.auth(e) : e
        end
        Array(r["result"]).first
      end

      def entries(integration)
        host = conf(integration, :host)
        info = rpc(integration, host, "system", "getSystemInformation").to_h
        [ entry(id: "bravia:#{info['macAddr'].presence || info['serial'].presence || host}", name: info["name"].presence || title, manufacturer: "Sony",
                model: info["model"], category: "Mídia", address: { "host" => host }, poll_s: 30,
                points: [ point("media", "media", name: "TV", history: "none", address: { "supports" => SUPPORTS }) ]) ]
      end

      def read(device)
        i = device.integration
        host = device.address["host"]
        on = rpc(i, host, "system", "getPowerStatus").to_h["status"] == "active"
        return { "media" => { "state" => "off" } } unless on

        speaker = Array(rpc(i, host, "audio", "getVolumeInformation")).find { |v| v["target"] == "speaker" }.to_h
        playing = begin
          rpc(i, host, "avContent", "getPlayingContentInfo").to_h
        rescue Integrations::Error
          {} # app aberto (não é entrada): a TV responde erro
        end
        { "media" => { "state" => "on", "volume" => speaker["volume"], "muted" => speaker["mute"], "source" => playing["title"].presence || playing["source"].presence,
                       "app" => playing["uri"].presence }.compact }
      end

      def command(point, command, value)
        i = point.device.integration
        host = point.device.address["host"]
        case command
        when "on", "off" then rpc(i, host, "system", "setPowerStatus", [ { status: command == "on" } ])
        when "volume" then rpc(i, host, "audio", "setAudioVolume", [ { target: "speaker", volume: value.to_i.to_s } ])
        when "volume_up", "volume_down" then rpc(i, host, "audio", "setAudioVolume", [ { target: "speaker", volume: command == "volume_up" ? "+2" : "-2" } ])
        when "mute" then rpc(i, host, "audio", "setAudioMute", [ { status: value == true } ])
        when "play_media" then rpc(i, host, "avContent", "setPlayContent", [ { uri: value.to_s } ])
        end
      end
    end
  end
end
