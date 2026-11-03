module MediaSources
  # Bibliotecas dos próprios players (o "browse media" de cada media_player
  # do HA): todo driver com `browse(device, path)` → [{"id", "title",
  # "container", "art", "play"}] aparece aqui (hoje: favoritos do Sonos). O
  # item só toca no player de onde veio. Id = "<ponto>|<o que o player toca>".
  class Players < Source
    describe key: "players", title: "Bibliotecas dos players", icon: "speakerphone",
             description: "Favoritos e listas guardados nas próprias caixas e TVs."
    texts en: { title: "Player libraries", description: "Favorites and playlists saved on the speakers and TVs themselves." },
          es: { title: "Bibliotecas de los reproductores", description: "Favoritos y listas guardados en los propios parlantes y TV." }

    class << self
      def driver(point) = Drivers::REGISTRY[point.device.driver]&.safe_constantize
      def with_library(site) = MediaSources.players(site).select { |p| driver(p).respond_to?(:browse) }
      def available?(site) = with_library(site).any?

      def browse(site, path, query: nil) # rubocop:disable Lint/UnusedMethodArgument
        return page(title, nil, with_library(site).map { |p| item(id: p.id, title: p.device.name, kind: "folder", subtitle: p.name) }) if path.blank?

        point_id, inner = path.to_s.split("|", 2)
        point = with_library(site).find { |p| p.id == point_id } or raise ArgumentError, "player sem biblioteca"
        items = driver(point).browse(point.device, inner).map do |i|
          item(id: "#{point.id}|#{i['container'] ? i['id'] : i['play']}", title: i["title"].to_s, kind: i["container"] ? "folder" : "audio", thumb: i["art"].presence)
        end
        page(point.device.name, "", items)
      rescue Integrations::Error, Drivers::MediaLan::Error => e
        raise ArgumentError, e.message
      end

      def media_url(_site, id) = id.to_s.split("|", 2).last
      def player_ids(_site, id) = [ id.to_s.split("|", 2).first ]
    end
  end
end
