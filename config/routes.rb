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
      patch :read_all, on: :collection, path: "todas-lidas"
    end

    # Câmeras (F8): quadro e ao vivo (WebRTC) passando pelo Rails.
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
          end
        end
      end

      resources :commands, only: :show

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
