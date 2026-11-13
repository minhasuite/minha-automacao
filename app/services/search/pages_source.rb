module Search
  # Páginas do menu (navegar), as mesmas que o menu mostra para a pessoa
  # (Leitor não vê Locais, Alertas, Perguntar e Configurações). Página nova entra na lista.
  class PagesSource < Source
    PAGES = [ [ "Início", "lightning-bolt", :root_path ], [ "Locais", "home", :sites_path, :staff ], [ "Alertas", "exclamation-circle", :alerts_path, :staff ],
              [ "Perguntar à casa", "sparkles", :ask_path, :staff ], [ "Notificações", "bell", :notifications_path ], [ "Configurações", "cog", :settings_path, :staff ],
              [ "Painéis", "view-boards", :settings_dashboards_path, :staff ], [ "Minha conta", "user-circle", :settings_account_path ] ].freeze

    def self.prefix = "page"

    def self.call(q, ctx)
      return [] if q.verb

      pages(ctx).select { |r| match?(q, r.title) }
    end

    def self.lookup(id, ctx) = pages(ctx).find { |r| r.key == "#{prefix}:#{id}" }

    def self.pages(ctx)
      PAGES.reject { |*, staff| staff && ctx.user.reader? }.map do |title, ico, route|
        Result.new(kind: I18n.t("search.kinds.page"), title: I18n.t("search.pages.#{route}", default: title), icon: ico, url: public_send(route), key: "#{prefix}:#{route}")
      end
    end
  end
end
