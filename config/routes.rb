Rails.application.routes.draw do
  # Liveness do container (Docker/Caddy).
  get "up" => "rails/health#show", as: :rails_health_check

  # Páginas públicas exigidas pela Play.
  get "privacidade", to: "legal#privacy", as: :privacy
  get "termos", to: "legal#terms", as: :terms
  get "exclusao", to: "legal#data_deletion", as: :data_deletion
  get "privacy", to: "legal#privacy"
  get "terms", to: "legal#terms"
  get "data-deletion", to: "legal#data_deletion"
  get "redefinir-senha", to: "legal#reset_password", as: :reset_password_page

  post "webhooks/google_play", to: "webhooks/google_play#create"

  # PWA (Lote 1): manifesto, service worker e o que ele chama sem sessão (a
  # resposta do botão com o token de uso único e a imagem por URL assinada).
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  post "push/resposta", to: "push#respond", as: :push_respond
  get "push/imagem", to: "push#image", as: :push_image
  # Respostas de mensageiro (Pacote 4: Telegram, WhatsApp): o plugin da integração valida.
  match "mensageiros/:id", to: "messenger_webhooks#receive", via: %i[get post], as: :messenger_webhook

  # Alexa Smart Home (F9): diretivas repassadas pela Lambda e tokens do account linking.
  post "alexa/smart_home", to: "alexa_smart_home#smart_home"
  post "oauth/token", to: "alexa_smart_home#token"
  get "oauth/autorizar", to: "web/oauth#new", as: :oauth_authorize
  post "oauth/autorizar", to: "web/oauth#create"

  # ---- Web (Hotwire, sessão em cookie) --------------------------------------
  get "entrar", to: "web/sessions#new", as: :login
  post "entrar", to: "web/sessions#create"
  post "entrar/google", to: "web/sessions#google", as: :google_login
  get "criar-conta", to: "web/sessions#new_signup", as: :signup
  post "criar-conta", to: "web/sessions#signup"
  delete "sair", to: "web/sessions#destroy", as: :logout
  get "convite/:token", to: "web/invites#show", as: :invite_link
  post "convite/:token", to: "web/invites#accept"
  get "esqueci-a-senha", to: "web/passwords#new", as: :forgot_password
  post "esqueci-a-senha", to: "web/passwords#create"

  scope module: :web do
    root "dashboard#show"

    resources :notifications, only: :index, path: "notificacoes" do
      patch :read, on: :member, path: "lida"
      patch :respond, on: :member, path: "responder"
      patch :read_all, on: :collection, path: "todas-lidas"
    end

    # Câmeras (F8): quadro e ao vivo (WebRTC) passando pelo Rails.
    # Busca global (Ctrl+K, uiweb).
    get "busca", to: "search#index", as: :search
    # Modo tablet de parede (uiweb): ajustes deste aparelho (cookie).
    patch "quiosque", to: "dashboards#kiosk_settings", as: :kiosk
    get "cameras/:id/quadro", to: "cameras#snapshot", as: :camera_snapshot
    post "cameras/:id/ao-vivo", to: "cameras#webrtc", as: :camera_webrtc

    # Retorno do OAuth de plugin de integração (F9: Google Agenda); `state` assinado.
    get "integracoes/oauth/retorno", to: "integrations#oauth_callback", as: :integrations_oauth_callback

    resources :alerts, only: :index, path: "alertas" do
      post :ack, on: :member, path: "ciente"
    end

    resources :sites, path: "locais", path_names: { new: "novo", edit: "editar" } do
      # Seção "Automações e cenas" (F8f): Automações · Cenas · Scripts ·
      # Blueprints · Regras (agendas, espelhamentos, avisos e alertas da F4).
      get :rules, on: :member, path: "regras"
      get :automation, on: :member, path: "automacao" # antiga: redireciona para Regras
      # Primitivas de automação (F4): criadas a partir do local ou do ponto.
      resources :point_links, path: "espelhamentos", except: %i[index show], shallow: true
      resources :schedules, path: "agendas", except: %i[index show], shallow: true
      resources :notify_rules, path: "avisos", except: %i[index show], shallow: true
      resources :alert_rules, path: "regras-de-alerta", except: %i[index show], shallow: true
      resources :scenes, path: "cenas", except: :show, shallow: true do
        post :activate, on: :member, path: "acionar"
      end
      # Sombra (F10): "teria feito", de-para da migração e comparações.
      resource :shadow, path: "sombra", only: %i[show update], controller: "shadow" do
        post :compare, path: "comparar"
        get "relatorios/:report_id", action: :report, as: :report
      end
      # Scripts (F8f): automação de `kind: "script"`; o editor, as versões e as
      # execuções são os das automações (rotas /automacoes/:id).
      resources :scripts, path: "scripts", only: %i[index new create], path_names: { new: "novo" }
      # Blueprints (F8f): prontos, importados do HA e "criar a partir de".
      resources :blueprints, path: "blueprints", except: :edit, path_names: { new: "importar" }, shallow: true do
        get :use, on: :member, path: "usar"
        post :use, on: :member, path: "usar", action: :instantiate
      end
      # Dashboards (F5): editor e versões só para técnico ou dono.
      resources :dashboards, path: "paineis", path_names: { new: "novo", edit: "editar" }, shallow: true do
        member do
          get "w/:widget_id", action: :widget, as: :widget
          patch :draft, path: "rascunho"
          post :publish, path: "publicar"
          post :discard, path: "descartar"
          post :revert, path: "voltar"
          get :json
          patch :json, action: :update_json
          post :prefer, path: "padrao"
          post :duplicate, path: "duplicar"
        end
      end
      # Automações da DSL (F6): editor, versões e simulação só para técnico ou dono.
      resources :automations, path: "automacoes", path_names: { new: "nova", edit: "editar" }, except: :show, shallow: true do
        post :bulk, on: :collection, path: "lote"
        member do
          get :run, path: "executar", action: :run_form
          patch :fields, path: "campos"
          post :rebuild, path: "refazer"
          patch :draft, path: "rascunho"
          post :publish, path: "publicar"
          post :discard, path: "descartar"
          post :revert, path: "voltar"
          get :json
          patch :json, action: :update_json
          get :simulate, path: "simular"
          post :simulate, path: "simular", action: :run_simulation
          post :run, path: "executar"
          post :webhook
        end
        resources :automation_runs, path: "execucoes", only: %i[index show], shallow: true
      end
      # Integrações (F8c): catálogo de plugins, assistente, login, varredura e adoção.
      resources :integrations, path: "integracoes", only: %i[index new create update destroy], path_names: { new: "nova" }, shallow: true do
        member do
          get :connect, path: "conectar"
          post :connect, path: "conectar", action: :login
          get :status, path: "estado"
          post :sync, path: "sincronizar"
          get :found, path: "encontrados"
          post :adopt, path: "adicionar"
        end
      end
      # Alexa Smart Home (F9): o que expor, nome falado, vínculos e cliente OAuth.
      resource :alexa, controller: "alexa", path: "alexa", only: %i[show update] do
        post :client, path: "cliente"
        delete "vinculos/:token_id", action: :unlink, as: :unlink
      end
      # Helpers (F8e): catálogo de tipos (plugins), lista com valor e cadastro.
      resources :helpers, controller: "site_helpers", path: "helpers", except: :show, path_names: { new: "novo", edit: "editar" }, shallow: true
      # Pacote 3: loja de pacotes declarativos e ferramentas de desenvolvedor (só administrador).
      resources :packages, path: "pacotes", only: %i[index show destroy], shallow: true do
        post :preview, on: :collection, path: "previa"
        post :install, on: :collection, path: "instalar"
        get :check, on: :member, path: "verificar"
      end
      member do
        get "ferramentas", to: "dev_tools#show", as: :dev_tools
        post "ferramentas/estado", to: "dev_tools#state", as: :dev_tools_state
        post "ferramentas/modelo", to: "dev_tools#template", as: :dev_tools_template
        post "ferramentas/acao", to: "dev_tools#command", as: :dev_tools_command
        post "ferramentas/evento", to: "dev_tools#event", as: :dev_tools_event
      end
      # Conjuntos de dados (Lote 2): o que as automações registram; lista com filtros e CSV.
      resources :datasets, path: "dados", path_names: { new: "novo", edit: "editar" }, shallow: true
      resources :areas, path: "areas", except: :index, shallow: true
      resources :devices, path: "dispositivos", shallow: true do
        post :bulk, on: :collection, path: "lote"
        post :refresh, on: :member, path: "atualizar"
        post :reconnect, on: :member, path: "reconectar"
        resources :points, path: "pontos", except: :index, shallow: true do
          post :command, on: :member, path: "comando"
        end
      end
    end

    # Configurações da instalação inteira (F8d): Painéis, Pessoas, Chaves de
    # integração e Sistema; mais a conta de quem está logado.
    get "configuracoes", to: "settings#show", as: :settings
    get "configuracoes/sistema", to: "settings#system", as: :settings_system
    patch "configuracoes/sistema", to: "settings#update_system"
    get "configuracoes/conta", to: "settings#account", as: :settings_account
    patch "configuracoes/conta", to: "settings#update_account"
    delete "configuracoes/conta", to: "settings#destroy_account"
    get "configuracoes/exportar", to: "settings#export", as: :settings_export
    post "configuracoes/zerar", to: "settings#wipe", as: :settings_wipe
    get "configuracoes/paineis", to: "settings#dashboards", as: :settings_dashboards
    # Saúde do sistema (registro Health::CHECKS) e o que falta para a troca (Cutover).
    get "configuracoes/saude", to: "health#show", as: :settings_health
    # IA da instalação (Lote 2): provedores (chave cifrada), teste, padrão, limite e uso.
    get "configuracoes/ia", to: "ai_settings#show", as: :settings_ai
    patch "configuracoes/ia", to: "ai_settings#update"
    patch "configuracoes/ia/:provider", to: "ai_settings#provider", as: :settings_ai_provider
    post "configuracoes/ia/:provider/teste", to: "ai_settings#check", as: :settings_ai_check
    # Perguntar à casa (Lote 2): só leitura, com os pontos do local como contexto.
    get "perguntar", to: "ask#show", as: :ask
    post "perguntar", to: "ask#create"
    # Assistente de voz (Pacote 3): áudio ou texto → intenção local ou "Perguntar à casa".
    post "assistente", to: "assist#create", as: :assist
    # Meus aparelhos (Lote 1): navegadores inscritos no Web Push.
    resources :push_subscriptions, path: "configuracoes/aparelhos", only: %i[index create destroy] do
      post :test, on: :collection, path: "teste"
    end
    scope "configuracoes" do
      resources :people, path: "pessoas", only: %i[index show create update destroy] do
        post :toggle, on: :member, path: "ativar"
        patch :sites, on: :member, path: "locais"
        post :invite, on: :collection, path: "convite"
      end
      resources :invites, path: "convites", only: :destroy
      resources :api_keys, path: "chaves", only: %i[index create destroy]
      # Aplicativos (F8g): catálogo em config/apps/*.yml, ações pelo supervisor.
      get "aplicativos/loja", to: "apps#store", as: :apps_store
      resources :apps, path: "aplicativos", param: :key, only: %i[index show update destroy], constraints: { key: /[a-z0-9_]+/ } do
        member do
          post :install, path: "instalar"
          post :act, path: "acao"
          post :upgrade, path: "atualizar"
          get :logs, path: "log"
          get :launch, path: "abrir"
        end
      end
    end
  end

  namespace :api do
    namespace :v1 do
      post "auth/signup", to: "auth#signup"
      post "auth/login", to: "auth#login"
      post "auth/google", to: "auth#google"
      post "auth/refresh", to: "auth#refresh"
      delete "auth/logout", to: "auth#logout"
      post "auth/password/forgot", to: "auth#password_forgot"
      post "auth/password/reset", to: "auth#password_reset"

      get "me", to: "me#show"
      patch "me", to: "me#update"
      delete "me", to: "me#destroy"
      get "me/export", to: "me#export"
      post "me/wipe", to: "me#wipe"
      get "me/sessions", to: "me#sessions"
      delete "me/sessions", to: "me#revoke_sessions"
      delete "me/sessions/:id", to: "me#revoke_session"

      get "company", to: "companies#show"
      patch "company", to: "companies#update"
      post "company/invites", to: "companies#invite"

      resources :notifications, only: :index do
        patch :read, on: :member
        post :respond, on: :member
        patch :read, on: :collection, action: :read_all
      end
      resources :device_tokens, only: %i[create destroy], param: :token, constraints: { token: %r{[^/]+} }
      resources :api_keys, only: %i[index create destroy]

      resources :sites, except: %i[new edit] do
        resources :helpers, controller: "site_helpers", only: :index
        resources :areas, except: %i[new edit], shallow: true
        resources :members, controller: :site_memberships, only: %i[index create update destroy], shallow: true
        resources :devices, except: %i[new edit], shallow: true do
          resources :points, except: %i[new edit], shallow: true do
            post :commands, on: :member, action: :command
            post :value, on: :member, action: :write_value
            get :history, on: :member
            get :snapshot, on: :member
          end
        end
        # App do celular (F7, G17): o aparelho se registra e manda os sensores.
        resources :mobile_devices, only: %i[create destroy], shallow: true do
          post :sensors, on: :member
        end
      end

      resources :commands, only: :show

      # Pacote 3: pessoas, voz, pacotes e ferramentas de desenvolvedor.
      get "sites/:site_id/people", to: "people#index"
      get "sites/:site_id/points", to: "points#site_index" # app2: widgets, atalhos e controles do Android
      post "sites/:site_id/assist", to: "assist#create"
      get "sites/:site_id/packages", to: "packages#index"
      post "sites/:site_id/packages/preview", to: "packages#preview"
      post "sites/:site_id/packages", to: "packages#create"
      resources :packages, only: %i[show update destroy]
      get "sites/:site_id/dev/states", to: "dev_tools#states"
      post "sites/:site_id/dev/states/:point_id", to: "dev_tools#set_state"
      post "sites/:site_id/dev/template", to: "dev_tools#template"
      post "sites/:site_id/dev/events", to: "dev_tools#fire_event"

      # Automação (F4).
      resources :sites, only: [] do
        resources :point_links, except: %i[new edit], shallow: true
        resources :schedules, except: %i[new edit], shallow: true
        resources :notify_rules, except: %i[new edit], shallow: true
        resources :alert_rules, except: %i[new edit], shallow: true
        resources :scenes, except: %i[new edit], shallow: true do
          post :activate, on: :member
        end
        # Scripts (F8f).
        resources :scripts, except: %i[new edit], shallow: true do
          post :run, on: :member
          get :runs, on: :member
        end
      end
      # Dashboards (F5).
      resources :sites, only: [] do
        resources :dashboards, except: %i[new edit], shallow: true do
          post :publish, on: :member
          post :revert, on: :member
          get :versions, on: :member
          get :definition, on: :member
        end
      end
      resources :alerts, only: %i[index show] do
        post :ack, on: :member
      end
      # Automações (F6).
      resources :sites, only: [] do
        resources :automations, except: %i[new edit], shallow: true do
          member do
            post :publish
            post :revert
            get :versions
            post :simulate
            post :run
            get :runs
            post :webhook
          end
        end
      end
      resources :automation_runs, only: :show
      post "hooks/automations/:token", to: "automation_hooks#create", as: :automation_hook

      get "billing", to: "billing#show"
      post "billing/google/verify", to: "billing#verify_google"
      get "ai/quota", to: "ai#quota"
      post "ai/ask", to: "ai#ask"
    end
  end
end
