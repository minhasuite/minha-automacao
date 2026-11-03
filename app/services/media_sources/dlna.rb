module MediaSources
  # Servidores DLNA da rede (o DLNA Digital Media Server do HA: Plex,
  # Jellyfin, minidlna, NAS): achados por SSDP na hora (guardados 5 min) e
  # navegados pelo ContentDirectory. Caminho = "<udn>" ou "<udn>/<objectId>".
  class Dlna < Source
    ST = "urn:schemas-upnp-org:device:MediaServer:1".freeze
    KIND = { "audioItem" => "audio", "videoItem" => "video", "imageItem" => "image", "audioBroadcast" => "radio" }.freeze

    describe key: "dlna", title: "Servidores DLNA", icon: "desktop-computer",
             description: "Bibliotecas de NAS, Plex, Jellyfin e outros servidores DLNA da rede de casa."
    texts en: { title: "DLNA servers", description: "Libraries from NAS, Plex, Jellyfin and other DLNA servers on your home network." },
          es: { title: "Servidores DLNA", description: "Bibliotecas de NAS, Plex, Jellyfin y otros servidores DLNA de la red de casa." }

    class << self
      def servers
        Rails.cache.fetch("media_sources/dlna_servers", expires_in: 5.minutes) do
          Ssdp.search(ST).filter_map do |s|
            d = Upnp.describe(s.dig("txt", "location").to_s)
            d.merge("control" => d["services"]["ContentDirectory"]) if d["services"]["ContentDirectory"]
          rescue Integrations::Error, URI::InvalidURIError
            nil
          end
        end
      end

      def server(udn) = servers.find { |s| s["udn"] == udn } || raise(ArgumentError, "servidor DLNA fora da rede")

      def browse(_site, path, query: nil) # rubocop:disable Lint/UnusedMethodArgument
        return page(title, nil, servers.map { |s| item(id: s["udn"], title: s["name"].to_s, kind: "folder", subtitle: s["model"]) }) if path.blank?

        udn, object = path.to_s.split("/", 2)
        s = server(udn)
        items = Upnp.browse(s["control"], object.presence || "0").map do |i|
          kind = i["container"] ? "folder" : KIND.find { |k, _| i["class"].to_s.include?(k) }&.last || "other"
          item(id: "#{udn}/#{i['id']}", title: i["title"].to_s, kind: kind, thumb: i["art"].presence)
        end
        page(s["name"].to_s, (object.present? ? udn : ""), items)
      rescue Integrations::Error => e
        raise ArgumentError, e.message
      end

      # O endereço do item vem do próprio servidor (rede de casa).
      def media_url(_site, id)
        udn, object = id.to_s.split("/", 2)
        Upnp.browse(server(udn)["control"], object, metadata: true).find { |i| i["url"] }&.dig("url") or raise ArgumentError, "item sem endereço"
      rescue Integrations::Error => e
        raise ArgumentError, e.message
      end
    end
  end
end
