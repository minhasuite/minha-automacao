module Search
  # Páginas do menu (navegar). Página nova entra na lista.
  class PagesSource < Source
    PAGES = [ [ "Início", "lightning-bolt", :root_path ], [ "Locais", "home", :sites_path ], [ "Alertas", "exclamation-circle", :alerts_path ],
              [ "Perguntar à casa", "sparkles", :ask_path ], [ "Notificações", "bell", :notifications_path ], [ "Configurações", "cog", :settings_path ],
              [ "Painéis", "view-boards", :settings_dashboards_path ] ].freeze

    def self.call(q, _ctx)
      return [] if q.verb

      PAGES.select { |title, _, _| match?(q, title) }.map { |title, ico, route| Result.new(kind: "Página", title: title, icon: ico, url: public_send(route)) }
    end
  end
end
