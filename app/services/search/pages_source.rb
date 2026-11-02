module Search
  # Páginas do menu (navegar), as mesmas que o menu mostra para a pessoa
  # (Leitor não vê Locais, Alertas, Perguntar e Configurações). Página nova entra na lista.
  class PagesSource < Source
    PAGES = [ [ "Início", "lightning-bolt", :root_path ], [ "Locais", "home", :sites_path, :staff ], [ "Alertas", "exclamation-circle", :alerts_path, :staff ],
              [ "Perguntar à casa", "sparkles", :ask_path, :staff ], [ "Notificações", "bell", :notifications_path ], [ "Configurações", "cog", :settings_path, :staff ],
              [ "Painéis", "view-boards", :settings_dashboards_path, :staff ], [ "Minha conta", "user-circle", :settings_account_path ] ].freeze

    def self.call(q, ctx)
      return [] if q.verb

      PAGES.select { |title, _, _, staff| !(staff && ctx.user.reader?) && match?(q, title) }
           .map { |title, ico, route| Result.new(kind: "Página", title: title, icon: ico, url: public_send(route)) }
    end
  end
end
