module Integrations
  # Reprodutor DLNA/UPnP (ondaC2, C9; o dlna_dmr do HA): TV, caixa ou
  # receiver da rede que toca um endereço (Drivers::Dlna). Achado por SSDP
  # (MediaRenderer); a descrição do aparelho diz as URLs de controle.
  class DlnaPlugin < MediaLanPlugin
    ST = "urn:schemas-upnp-org:device:MediaRenderer:1".freeze
    PATHS = %w[/description.xml /dmr /rootDesc.xml /upnp/desc.xml].freeze

    describe key: "dlna", title: "Reprodutor DLNA", icon: "speakerphone",
             description: "TV, caixa ou receiver com DLNA/UPnP na rede: tocar música, rádio, vídeo e falas, volume, mudo, pausar e avançar."
    texts en: { title: "DLNA renderer", description: "TV, speaker or receiver with DLNA/UPnP on your network: play music, radio, video and speech, volume, mute, pause and skip." },
          es: { title: "Reproductor DLNA", description: "TV, parlante o receptor con DLNA/UPnP en la red: reproducir música, radio, video y voz, volumen, silencio, pausa y avanzar." },
          "pt-BR" => { no_description: "O aparelho não respondeu como reprodutor DLNA." }
    texts en: { no_description: "The device didn't answer as a DLNA renderer." }, es: { no_description: "El aparato no respondió como reproductor DLNA." }
    port 49_152
    ssdp ST

    def self.probe(integration)
      d = locate(host_of(integration), port_of(integration))
      av, rc = d["services"].values_at("AVTransport", "RenderingControl")
      raise Integrations::Error, text(:no_description) unless av && rc

      Drivers::MediaLan.entry(integration, "dlna:#{d['udn'].presence || host_of(integration)}", kind: "dlna", supports: Drivers::Dlna::SUPPORTS,
                                                                                               port: port_of(integration), address: { "av" => av, "rc" => rc },
                                                                                               manufacturer: d["manufacturer"], model: d["model"], name: d["name"])
    end

    # Endereço da descrição: o que o SSDP anunciar para o IP; sem resposta, os caminhos comuns.
    def self.locate(host, port)
      found = Ssdp.search(ST).find { |s| s["host"] == host }&.dig("txt", "location")
      ([ found ].compact + PATHS.map { |p| "http://#{host}:#{port}#{p}" }).each do |url|
        d = Upnp.describe(url)
        return d if d["services"].key?("AVTransport")
      rescue Integrations::Error
        next
      end
      raise Integrations::Error, text(:no_description)
    end
  end
end
