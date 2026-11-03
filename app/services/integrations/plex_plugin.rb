module Integrations
  # Plex (catalogo): o Plex Media Server da casa pela API do servidor (token
  # X-Plex-Token da conta do dono). Quantos assistem agora e o tamanho de cada
  # biblioteca; cada player que aparece assistindo vira um ponto de mídia
  # (o que toca, pausar e continuar pelo servidor).
  class PlexPlugin < SchemaPlugin
    describe key: "plex", title: "Plex Media Server", icon: "play",
             description: "Plex Media Server: quem está assistindo e o quê, pausar e continuar cada player e o tamanho das bibliotecas (filmes, séries, músicas)."
    texts "pt-BR" => { fields: { token: "Token do Plex (X-Plex-Token)" }, points: { watching: "Assistindo agora", library: "Biblioteca: %{name}" },
                       note: "Token: no Plex Web, abra um item → ⋯ → Obter informações → Ver XML; o endereço termina em X-Plex-Token=…" },
          en: { title: "Plex Media Server", description: "Plex Media Server: who's watching what, pause and resume each player and the size of each library (movies, shows, music).",
                fields: { token: "Plex token (X-Plex-Token)" }, points: { watching: "Watching now", library: "Library: %{name}" },
                note: "Token: in Plex Web, open an item → ⋯ → Get Info → View XML; the address ends in X-Plex-Token=…" },
          es: { title: "Plex Media Server", description: "Plex Media Server: quién está viendo y qué, pausar y continuar cada reproductor y el tamaño de cada biblioteca (películas, series, música).",
                fields: { token: "Token de Plex (X-Plex-Token)" }, points: { watching: "Viendo ahora", library: "Biblioteca: %{name}" },
                note: "Token: en Plex Web, abre un ítem → ⋯ → Obtener información → Ver XML; la dirección termina en X-Plex-Token=…" }
    field :host, required: true
    field :port, :number, default: 32_400
    field :token, secret: true, required: true
    mdns "_plexmediasvr._tcp"
    SUPPORTS = %w[resume pause].freeze

    class << self
      def get(integration, path, extra = {})
        base = LanHttp.base("#{conf(integration, :host)}:#{conf(integration, :port)}")
        LanHttp.get("#{base}#{path}", headers: { "Accept" => "application/json", "X-Plex-Token" => conf(integration, :token).to_s,
                                                 "X-Plex-Client-Identifier" => "minha-automacao" }.merge(extra))["MediaContainer"].to_h
      end

      def sessions(integration) = Array(get(integration, "/status/sessions")["Metadata"])

      def entries(integration)
        id = get(integration, "/identity")["machineIdentifier"]
        libs = Array(get(integration, "/library/sections")["Directory"])
        server = entry(id: "plex:#{id}", name: integration.name, manufacturer: "Plex", category: "Mídia", poll_s: 60, address: { "server" => true },
                       points: [ point("watching", state_class: "measurement", icon: "play") ] +
                               libs.map { |l| point("library:#{l['key']}", name: text("points.library", name: l["title"]), state_class: "measurement", icon: "collection") })
        players = sessions(integration).filter_map do |s|
          pl = s["Player"].to_h
          next if pl["machineIdentifier"].blank?

          entry(id: "plex:player:#{pl['machineIdentifier']}", name: pl["title"].presence || pl["product"], manufacturer: "Plex", model: pl["product"], category: "Mídia",
                address: { "client" => pl["machineIdentifier"] }, poll_s: 30,
                points: [ point("media", "media", name: text("points.player"), history: "none", address: { "supports" => SUPPORTS }) ])
        end
        [ server ] + players
      end

      def read(device)
        i = device.integration
        list = sessions(i)
        if device.address["server"]
          out = { "watching" => list.size }
          Array(get(i, "/library/sections")["Directory"]).each do |l|
            out["library:#{l['key']}"] = get(i, "/library/sections/#{l['key']}/all", "X-Plex-Container-Start" => "0", "X-Plex-Container-Size" => "0")["totalSize"]
          end
          return out
        end

        s = list.find { |x| x.dig("Player", "machineIdentifier") == device.address["client"] }
        return { "media" => { "state" => "idle" } } unless s

        state = s.dig("Player", "state") == "paused" ? "paused" : "playing"
        { "media" => { "state" => state, "title" => s["title"], "artist" => s["grandparentTitle"].presence, "album" => s["parentTitle"].presence, "app" => s.dig("Player", "product") }.compact }
      end

      def command(point, command, _value)
        i = point.device.integration
        get(i, "/player/playback/#{command == 'pause' ? 'pause' : 'play'}?type=video", "X-Plex-Target-Client-Identifier" => point.device.address["client"])
      end
    end
  end
end
