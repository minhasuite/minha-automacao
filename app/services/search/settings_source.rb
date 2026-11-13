module Search
  # Configurações e ajuda: cada item da subnavegação de Configurações que a pessoa vê
  # (`SettingsNav`, a mesma lista do menu), achado pelo nome ou pelas palavras de
  # `search.settings_words.<chave>` ("senha" → Segurança, "backup" → Cópias).
  class SettingsSource < Source
    def self.prefix = "setting"

    def self.call(q, ctx)
      return [] if q.verb

      items(ctx).select { |r, words| match?(q, r.title, words) }.map(&:first)
    end

    def self.lookup(id, ctx) = items(ctx).map(&:first).find { |r| r.key == "#{prefix}:#{id}" }

    def self.items(ctx)
      section = I18n.t("nav.settings")
      SettingsNav.items(ctx.user).map do |i|
        [ Result.new(kind: I18n.t("search.kinds.setting"), title: i[:label], subtitle: section, icon: i[:icon], url: i[:path], key: "#{prefix}:#{i[:key]}"),
          I18n.t("search.settings_words.#{i[:key]}", default: "") ]
      end
    end
  end
end
