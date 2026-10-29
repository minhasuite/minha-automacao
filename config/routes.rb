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

  # ---- Web (Hotwire, sessão em cookie) --------------------------------------
  get "entrar", to: "web/sessions#new", as: :login
  post "entrar", to: "web/sessions#create"
  post "entrar/google", to: "web/sessions#google", as: :google_login
  get "criar-conta", to: "web/sessions#new_signup", as: :signup
  post "criar-conta", to: "web/sessions#signup"
  delete "sair", to: "web/sessions#destroy", as: :logout
  get "esqueci-a-senha", to: "web/passwords#new", as: :forgot_password
  post "esqueci-a-senha", to: "web/passwords#create"

  scope module: :web do
    root "dashboard#show"

    resources :notifications, only: :index, path: "notificacoes" do
      patch :read, on: :member, path: "lida"
      patch :read_all, on: :collection, path: "todas-lidas"
    end

    get "configuracoes", to: "settings#show", as: :settings
    patch "configuracoes/empresa", to: "settings#update_company", as: :settings_company
    patch "configuracoes/conta", to: "settings#update_account", as: :settings_account
    get "configuracoes/exportar", to: "settings#export", as: :settings_export
    post "configuracoes/zerar", to: "settings#wipe", as: :settings_wipe
    delete "configuracoes/conta", to: "settings#destroy_account"
    post "configuracoes/entrar-em-empresa", to: "settings#join", as: :settings_join
    post "configuracoes/convite", to: "settings#invite", as: :settings_invite
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
      post "company/join", to: "companies#join"

      resources :notifications, only: :index do
        patch :read, on: :member
        patch :read, on: :collection, action: :read_all
      end
      resources :device_tokens, only: %i[create destroy], param: :token, constraints: { token: %r{[^/]+} }
      resources :api_keys, only: %i[index create destroy]

      get "billing", to: "billing#show"
      post "billing/google/verify", to: "billing#verify_google"
      get "ai/quota", to: "ai#quota"
      post "ai/ask", to: "ai#ask"
    end
  end
end
