module MediaSources
  # Interface de uma fonte de mídia. `browse(site, path, query:)` → Page;
  # `media_url(site, id)` → o que o player recebe no `play_media` (URL
  # absoluta ou id que o próprio player entende); `player_ids(site, id)` →
  # pontos que tocam o item (nil = todos os players); `preview_url` → o
  # navegador toca ali mesmo (nil = sem prévia).
  class Source
    extend PluginTexts
    translates :title, :description

    class << self
      attr_reader :key, :icon

      def describe(key:, title:, icon:, description:)
        @key = key
        @title = title
        @icon = icon
        @description = description
      end

      def available?(_site) = true
      def searchable? = false
      def uploads? = false
      def browse(_site, _path, query: nil) = raise(NotImplementedError)
      def media_url(_site, id) = id
      def preview_url(_site, _id) = nil
      def player_ids(_site, _id) = nil

      def page(title, parent, items) = Page.new(title: title, parent: parent, items: items)
      def item(**) = Item.new(**)
    end
  end
end
