module Web
  # PWA (Lote 1; iPhone em pwa-ios, docs/pwa.md): manifesto no idioma de quem pede, service worker com
  # versão (muda com o CSS e a versão do app, e o navegador atualiza) e a página "Sem conexão com a casa"
  # que ele guarda. Nada aqui depende de sessão nem mostra dado da casa: a página sem conexão é a mesma
  # para todo mundo e é a única coisa que o service worker guarda.
  class PwaController < ApplicationController
    skip_before_action :require_login!
    skip_forgery_protection only: :service_worker
    layout false

    def manifest
      render "pwa/manifest", formats: :json, content_type: "application/manifest+json"
    end

    def service_worker
      @offline_assets = [ offline_path, helpers.asset_path("tailwind.css"), "/icon-192.png" ]
      @version = Digest::SHA256.hexdigest([ Updates.current_tag, Updates.current_commit, *@offline_assets, I18n.locale ].join("|"))[0, 12]
      response.headers["Cache-Control"] = "no-cache"
      render "pwa/service-worker", formats: :js, content_type: "text/javascript"
    end

    def offline
      response.headers["Cache-Control"] = "no-store"
    end
  end
end
