Rails.application.routes.draw do
  # Liveness do container (Docker/Caddy).
  get "up" => "rails/health#show", as: :rails_health_check

  # ondaB1 (B7): servidor MCP (JSON-RPC; token MCP do local).
  post "mcp", to: "mcp#create", as: :mcp
  get "mcp", to: "mcp#show"

  # Páginas públicas exigidas pela Play.
  get "privacidade", to: "legal#privacy", as: :privacy
  get "termos", to: "legal#terms", as: :terms
  get "exclusao", to: "legal#data_deletion", as: :data_deletion
  get "privacy", to: "legal#privacy"
  get "terms", to: "legal#terms"
  get "data-deletion", to: "legal#data_deletion"
  get "redefinir-senha", to: "legal#reset_password", as: :reset_password_page
  # appweb2: o app Android pode criar e usar passkeys deste domínio (Credential Manager).
  get ".well-known/assetlinks.json", to: "legal#assetlinks", format: false

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
  # ondaC1 (C6): Google Home cloud-to-cloud (SYNC/QUERY/EXECUTE/DISCONNECT).
  post "google/smart_home", to: "google_smart_home#fulfill", as: :google_smart_home
  post "oauth/token", to: "alexa_smart_home#token", as: :oauth_token
  get "oauth/autorizar", to: "web/oauth#new", as: :oauth_authorize
  post "oauth/autorizar", to: "web/oauth#create"

  # ---- Web (Hotwire, sessão em cookie) --------------------------------------
  get "entrar", to: "web/sessions#new", as: :login
  # appweb: o app abre esta página no navegador (link de uso único) já logado.
  get "entrar/ponte", to: "web/sessions#bridge", as: :login_bridge
  # ondaA2 A20: JS dos cards de terceiros pelo hash (público, imutável; o iframe sandbox não manda cookie).
  get "cartoes/:sha.js", to: "cards#show", constraints: { sha: /\h{64}/ }, format: false
  post "entrar", to: "web/sessions#create"
  post "entrar/google", to: "web/sessions#google", as: :google_login
  # ondaA2 A16: segunda etapa e entrar com passkey.
  get "entrar/codigo", to: "web/sessions#mfa", as: :login_mfa
  post "entrar/codigo", to: "web/sessions#verify_mfa"
  get "entrar/passkey", to: "web/sessions#passkey_options", as: :login_passkey
  post "entrar/passkey", to: "web/sessions#passkey"
  get "criar-conta", to: "web/sessions#new_signup", as: :signup
  post "criar-conta", to: "web/sessions#signup"
  delete "sair", to: "web/sessions#destroy", as: :logout
  get "convite/:token", to: "web/invites#show", as: :invite_link
  post "convite/:token", to: "web/invites#accept"
  get "esqueci-a-senha", to: "web/passwords#new", as: :forgot_password
  # Produto: idioma da tela e a primeira configuração (passos em Onboarding::STEPS).
  patch "idioma", to: "web/locales#update", as: :locale
  get "primeira-configuracao", to: "web/onboarding#show", as: :onboarding
  get "primeira-configuracao/descobrir", to: "web/onboarding#discover", as: :onboarding_discover
  post "primeira-configuracao/concluir", to: "web/onboarding#finish", as: :onboarding_finish
  get "primeira-configuracao/:step", to: "web/onboarding#show", as: :onboarding_step
  post "primeira-configuracao/:step", to: "web/onboarding#update"
  post "primeira-configuracao/:step/pular", to: "web/onboarding#skip", as: :onboarding_skip
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
    # ondaC2 (C10): gravação, PTZ e alto-falante da câmera. Arquivo de mídia por link assinado (players da rede, sem sessão).
    patch "cameras/:id/ajustes", to: "cameras#settings", as: :camera_settings
    get "midia/arquivo/:name", to: "media_files#show", as: :media_file, constraints: { name: %r{[^/]+} }, format: false
    # "Falar na Alexa": a voz gravada (MP3) que a Echo baixa, sem sessão; e o envio do painel.
    get "fala/:key.mp3", to: "talk_audios#show", as: :talk_audio, constraints: { key: /[a-z0-9]{20,40}/ }, format: false
    post "locais/:site_id/falar-na-alexa", to: "talks#create", as: :site_talk

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
      # "Migre do HA em 10 minutos": conectar, revisar e escolher, importar e conferir.
      resource :ha_migration, path: "migrar-do-ha", only: :show, controller: "ha_migrations" do
        post :connect, path: "conectar"
        post :import, path: "importar"
        post :dashboards, path: "paineis"
        post :reset, path: "recomecar"
      end
      # Painel pronto (Dashboards::Presets, ex.: Energia): antes de /paineis/:id.
      get "paineis/prontos", to: "dashboard_presets#index", as: :dashboard_presets
      get "paineis/prontos/:key", to: "dashboard_presets#new", as: :dashboard_preset
      post "paineis/prontos/:key", to: "dashboard_presets#create"
      # Dashboards (F5): editor e versões só para técnico ou dono.
      resources :dashboards, path: "paineis", path_names: { new: "novo", edit: "editar" }, shallow: true do
        member do
          get "w/:widget_id", action: :widget, as: :widget
          get "w/:widget_id/pontos", action: :widget_points, as: :widget_points
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
          # POST também: o Duplicar do Ss::BlockComponent é um link Turbo com POST.
          match :draft, path: "rascunho", via: %i[patch post]
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
          get :diagnostics, path: "diagnostico"
          post :debug, path: "depuracao" # resto (7.7): liga ou desliga (e baixa) o log de depuração
          post :adopt, path: "adicionar"
          # ondaC1: tela "Gerenciar" do plugin (Z-Wave, Matter, Thread, Bluetooth…).
          get :panel, path: "gerenciar"
          post "gerenciar/:acao", action: :panel_action, as: :panel_action, constraints: { acao: /[a-z_]+/ }
        end
      end
      # ondaC2 (C8/C9): mídia do local (players, falar, navegador das fontes).
      get "midia", to: "media#index", as: :media
      get "midia/fontes/:source", to: "media#browse", as: :media_browse
      post "midia/tocar", to: "media#play", as: :media_play
      post "midia/falar", to: "media#speak", as: :media_speak
      post "midia/players/:id", to: "media#control", as: :media_control
      post "midia/pastas", to: "media#mkdir", as: :media_folders
      post "midia/arquivos", to: "media#upload", as: :media_files
      delete "midia/arquivos", to: "media#destroy", as: :media_file_delete
      # ondaA1 (A11): listas de tarefas e agenda local do local.
      resources :todo_lists, controller: "todo_lists", path: "listas", only: %i[index] do
        post :items, on: :member, path: "itens", action: :add
        patch "itens/:uid", on: :member, action: :toggle, as: :toggle_item
        delete "itens/:uid", on: :member, action: :remove, as: :remove_item
        delete :completed, on: :member, path: "concluidos", action: :clear
      end
      resource :agenda, controller: "agenda", path: "agenda", only: %i[show create] do
        delete "eventos/:point_id/:uid", action: :destroy, as: :event
      end
      # ondaA1 (A3): tela Expor (Assist, Alexa e pontes numa tela só, em massa).
      resource :exposure, controller: "exposures", path: "expor", only: %i[show update]
      # ondaB1: assistente de voz do local (pipelines, depuração, frases, satélites, MCP).
      get "assistente", to: "assist_settings#show", as: :assist_settings
      post "assistente/pipelines", to: "assist_settings#create_pipeline", as: :assist_pipelines
      patch "assistente/pipelines/:id", to: "assist_settings#update_pipeline", as: :assist_pipeline
      delete "assistente/pipelines/:id", to: "assist_settings#destroy_pipeline"
      post "assistente/satelites", to: "assist_settings#create_satellite", as: :assist_satellites
      patch "assistente/satelites/:id", to: "assist_settings#update_satellite", as: :assist_satellite
      delete "assistente/satelites/:id", to: "assist_settings#destroy_satellite"
      post "assistente/satelites/:id/testar", to: "assist_settings#test_satellite", as: :assist_satellite_test
      post "assistente/mcp", to: "assist_settings#create_mcp_token", as: :assist_mcp_tokens
      # P3: intenções (frase → cena ou script) e respostas personalizadas da voz.
      post "assistente/intencoes", to: "assist_settings#create_intent", as: :assist_intents
      patch "assistente/intencoes/:id", to: "assist_settings#update_intent", as: :assist_intent
      delete "assistente/intencoes/:id", to: "assist_settings#destroy_intent"
      post "assistente/respostas", to: "assist_settings#create_response", as: :assist_responses
      patch "assistente/respostas/:id", to: "assist_settings#update_response", as: :assist_response
      delete "assistente/respostas/:id", to: "assist_settings#destroy_response"
      delete "assistente/mcp/:id", to: "assist_settings#revoke_mcp_token", as: :assist_mcp_token
      # Alexa Smart Home (F9): o que expor, nome falado, vínculos e cliente OAuth.
      resource :alexa, controller: "alexa", path: "alexa", only: %i[show update] do
        post :client, path: "cliente"
        delete "vinculos/:token_id", action: :unlink, as: :unlink
      end
      # integ: pontes de exposição (Matter…): o que expor, pareamento e chave do serviço.
      resources :bridges, controller: "bridges", path: "pontes", only: %i[show update], param: :key do
        post :service_key, on: :member, path: "chave"
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
        post "ferramentas/estatisticas", to: "dev_tools#stats_adjust", as: :dev_tools_stats_adjust
        delete "ferramentas/estatisticas/:point_id", to: "dev_tools#stats_purge", as: :dev_tools_stats_purge
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
          post :reset, on: :member, path: "redefinir" # "Redefinir estado" do sensor (técnico+)
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
    # Padrões dos painéis do local (P1.1/ideia 22): itens do cartão de área e o limite do "dado velho".
    get "configuracoes/paineis/padroes/:site_id", to: "dashboard_defaults#edit", as: :settings_dashboard_defaults
    patch "configuracoes/paineis/padroes/:site_id", to: "dashboard_defaults#update"
    # P2.1 e ideias 3, 6 e 8: regras de arrumação, "Arrumar esta visão", visão automática, montagem por frase e assistente.
    get "configuracoes/paineis/arrumacao/:site_id", to: "arrange_rules#edit", as: :settings_arrange_rules
    patch "configuracoes/paineis/arrumacao/:site_id", to: "arrange_rules#update"
    get "paineis/:id/arrumar", to: "dashboard_arrange#preview", as: :arrange_dashboard
    post "paineis/:id/arrumar", to: "dashboard_arrange#apply"
    post "paineis/:id/visao-automatica", to: "dashboard_arrange#auto_view", as: :auto_view_dashboard
    post "paineis/:id/congelar", to: "dashboard_arrange#freeze_view", as: :freeze_view_dashboard
    post "paineis/:id/montar", to: "dashboard_arrange#compose", as: :compose_dashboard
    get "paineis/:id/mudancas", to: "dashboard_arrange#changes", as: :changes_dashboard
    get "locais/:site_id/paineis/assistente", to: "dashboard_wizard#new", as: :site_dashboard_wizard
    post "locais/:site_id/paineis/assistente", to: "dashboard_wizard#create"
    # Produto: atualização do servidor e acesso remoto (provedores).
    post "configuracoes/sistema/atualizar", to: "settings#update_server", as: :settings_update
    post "configuracoes/sistema/atualizacao", to: "settings#update_updates", as: :settings_updates
    # ondaA1 (A2): rótulos (cor, nome, uso) e a tela Expor (A3).
    resources :tags, path: "configuracoes/rotulos", only: %i[index update destroy]
    get "configuracoes/acesso-remoto", to: "remote_access#show", as: :settings_remote
    patch "configuracoes/acesso-remoto", to: "remote_access#update"
    delete "configuracoes/acesso-remoto", to: "remote_access#destroy"
    # Saúde do sistema (registro Health::CHECKS) e o que falta para a troca (Cutover).
    get "configuracoes/saude", to: "health#show", as: :settings_health
    post "configuracoes/saude/ignorar", to: "health#ignore", as: :settings_health_ignore
    post "configuracoes/saude/reparar", to: "health#repair", as: :settings_health_repair
    # P3: verificações personalizadas da Saúde (consulta/expressão + texto), só administradores.
    resources :custom_health_checks, path: "configuracoes/saude/verificacoes", as: :settings_health_checks, except: :show,
                                     path_names: { new: "nova", edit: "editar" }
    get "configuracoes/hardware", to: "hardware#show", as: :settings_hardware
    # resto (7.3): IP e Wi-Fi do host (NetworkManager pelo supervisor)
    post "configuracoes/hardware/rede", to: "hardware#network", as: :settings_hardware_network
    post "configuracoes/hardware/wifi", to: "hardware#wifi", as: :settings_hardware_wifi
    post "configuracoes/sistema/firmware/:point_id", to: "firmware#create", as: :settings_firmware
    get "configuracoes/backups", to: "backups#show", as: :settings_backups
    post "configuracoes/backups", to: "backups#restore"
    post "configuracoes/backups/agora", to: "backups#create", as: :settings_backups_now # resto (7.12)
    get "configuracoes/seguranca", to: "security#show", as: :settings_security
    post "configuracoes/seguranca/totp", to: "security#enable_totp", as: :settings_security_totp
    delete "configuracoes/seguranca/totp", to: "security#disable_totp"
    post "configuracoes/seguranca/recuperacao", to: "security#recovery", as: :settings_security_recovery
    get "configuracoes/seguranca/passkeys/opcoes", to: "security#passkey_options", as: :settings_passkey_options
    post "configuracoes/seguranca/passkeys", to: "security#create_passkey", as: :settings_passkeys
    delete "configuracoes/seguranca/passkeys/:id", to: "security#destroy_passkey", as: :settings_passkey
    post "configuracoes/seguranca/google", to: "security#link_google", as: :settings_security_google
    delete "configuracoes/seguranca/google", to: "security#unlink_google"
    get "configuracoes/logs", to: "logs#show", as: :settings_logs
    # Fila e jobs (docs/fila.md): Solid Queue + latência dos comandos; só o dono, como os Logs.
    get "configuracoes/fila", to: "queue#show", as: :settings_queue
    post "configuracoes/fila/erros/:id/tentar", to: "queue#retry_job", as: :settings_queue_retry
    delete "configuracoes/fila/erros/:id", to: "queue#discard_job", as: :settings_queue_discard
    get "configuracoes/aparencia", to: "appearance#show", as: :settings_appearance
    patch "configuracoes/aparencia", to: "appearance#update"
    post "configuracoes/aparencia/temas", to: "appearance#create_theme", as: :settings_themes
    patch "configuracoes/aparencia/temas/:id", to: "appearance#update_theme", as: :settings_theme
    delete "configuracoes/aparencia/temas/:id", to: "appearance#destroy_theme"
    delete "configuracoes/logs", to: "logs#destroy"
    post "configuracoes/hardware/:acao", to: "hardware#power", as: :settings_hardware_power
    # Backup no Google Drive: conectar volta por integrations#oauth_callback.
    delete "configuracoes/saude/google-drive", to: "health#disconnect_drive", as: :settings_health_drive
    # IA da instalação (Lote 2): provedores (chave cifrada), teste, padrão, limite e uso.
    get "configuracoes/ia", to: "ai_settings#show", as: :settings_ai
    patch "configuracoes/ia", to: "ai_settings#update"
    patch "configuracoes/ia/:provider", to: "ai_settings#provider", as: :settings_ai_provider
    post "configuracoes/ia/:provider/teste", to: "ai_settings#check", as: :settings_ai_check
    # Perguntar à casa (Lote 2): só leitura, com os pontos do local como contexto.
    get "perguntar", to: "ask#show", as: :ask
    post "perguntar", to: "ask#create"
    post "perguntar/painel", to: "ask#widget", as: :ask_widget # card "Perguntar à casa" do painel (resposta no frame dele)
    # Assistente de voz (Pacote 3): áudio ou texto → intenção local ou "Perguntar à casa".
    post "assistente", to: "assist#create", as: :assist
    # Paridade com o HA (roadmap de vendas): Diário, Histórico e Mapa da instalação (um local por vez).
    get "diario", to: "logbook#show", as: :logbook
    get "historico", to: "history#show", as: :history
    get "paineis-extras/:package_id/:key", to: "custom_panels#show", as: :custom_panel, constraints: { key: /[a-z0-9_-]+/ } # resto: panel_custom
    get "mapa", to: "maps#show", as: :map
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
      # resto (7.13): repositórios de apps de terceiros (imagem fixada por digest).
      post "aplicativos/repositorios", to: "apps#add_repository", as: :app_repositories
      delete "aplicativos/repositorios", to: "apps#remove_repository"
      resources :apps, path: "aplicativos", param: :key, only: %i[index show update destroy], constraints: { key: /[a-z0-9_]+/ } do
        member do
          post :install, path: "instalar"
          post :act, path: "acao"
          post :upgrade, path: "atualizar"
          get :logs, path: "log"
          get :launch, path: "abrir"
          post :connect, path: "conectar"
        end
      end
    end
  end

  namespace :api do
    namespace :v1 do
      post "auth/signup", to: "auth#signup"
      post "auth/login", to: "auth#login"
      get "auth/providers", to: "auth#providers"
      post "auth/google", to: "auth#google"
      post "auth/refresh", to: "auth#refresh"
      delete "auth/logout", to: "auth#logout"
      post "auth/password/forgot", to: "auth#password_forgot"
      post "auth/password/reset", to: "auth#password_reset"
      # appweb2: passkey pelo Credential Manager do Android (entrar e criar).
      post "auth/passkey/options", to: "auth#passkey_options"
      post "auth/passkey", to: "auth#passkey"
      get "me/passkeys/options", to: "me#passkey_options"
      post "me/passkeys", to: "me#create_passkey"
      post "me/google", to: "me#link_google"
      delete "me/google", to: "me#unlink_google"

      # appweb: telas da web transcodificadas para o app (AppScreen).
      get "screen", to: "screens#show"
      post "screen", to: "screens#create"
      post "screen/bridge", to: "screens#bridge"

      get "me", to: "me#show"
      patch "me", to: "me#update"
      delete "me", to: "me#destroy"
      get "me/export", to: "me#export"
      post "me/wipe", to: "me#wipe"
      get "me/sessions", to: "me#sessions"
      get "themes", to: "me#themes"
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
            post :reset, on: :member # "Redefinir estado" do sensor (técnico+, auditado)
            get :history, on: :member
            get :snapshot, on: :member
            post :talk, on: :member # ondaC2 (C10): áudio gravado no app vai para o alto-falante da câmera
            post :webrtc, on: :member # appweb2: câmera ao vivo no app (SDP do go2rtc)
          end
        end
        # App do celular (F7, G17): o aparelho se registra e manda os sensores.
        resources :mobile_devices, only: %i[create destroy], shallow: true do
          post :sensors, on: :member
          post :tag, on: :member # appweb D4: tag NFC/QR lida no celular
        end
      end

      resources :commands, only: :show

      # integ: serviço da ponte (matter-bridge) lê os expostos, manda a situação e os comandos.
      get "bridges/:key", to: "bridges#index"
      put "bridges/:key/status", to: "bridges#status"
      post "bridges/:key/commands", to: "bridges#command"
      # ondaC1 (C2): o serviço ble-scanner manda os anúncios do adaptador do servidor.
      post "bluetooth/advertisements", to: "bluetooth#advertisements"
      post "dhcp/leases", to: "dhcp#leases" # resto (7.23): escuta passiva de DHCP

      # Pacote 3: pessoas, voz, pacotes e ferramentas de desenvolvedor.
      get "sites/:site_id/people", to: "people#index"
      get "sites/:site_id/points", to: "points#site_index" # app2: widgets, atalhos e controles do Android
      # Diário, Histórico de vários pontos e Mapa (paridade com o HA).
      get "sites/:site_id/logbook", to: "logbook#index"
      get "sites/:site_id/detections", to: "detections#index"
      get "sites/:site_id/history", to: "history#index"
      get "sites/:site_id/map", to: "maps#index"
      post "sites/:site_id/assist", to: "assist#create"
      get "sites/:site_id/assist/pipelines", to: "assist#pipelines" # appweb2 D5
      post "sites/:site_id/assist/wake", to: "assist#wake" # appweb2 D5: palavra de ativação no celular
      get "sites/:site_id/packages", to: "packages#index"
      post "sites/:site_id/packages/preview", to: "packages#preview"
      post "sites/:site_id/packages", to: "packages#create"
      resources :packages, only: %i[show update destroy]
      get "sites/:site_id/dev/states", to: "dev_tools#states"
      post "sites/:site_id/dev/states/:point_id", to: "dev_tools#set_state"
      post "sites/:site_id/dev/template", to: "dev_tools#template"
      post "sites/:site_id/dev/events", to: "dev_tools#fire_event"
      get "system/queue", to: "system_queue#show" # Fila e jobs (docs/fila.md), só o dono
      # P3: Saúde (resultado e verificações personalizadas, só administradores), prévia de texto e voz personalizada.
      get "health", to: "health#show"
      post "health_checks/preview", to: "custom_health_checks#preview"
      resources :custom_health_checks, path: "health_checks", except: %i[new edit]
      post "sites/:site_id/message_preview", to: "message_previews#create"
      resources :sites, only: [] do
        resources :assist_custom_intents, path: "assist/intents", except: %i[new edit], shallow: true
        resources :assist_custom_responses, path: "assist/responses", except: %i[new edit], shallow: true
      end

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
        post :talk, on: :member, to: "talks#create" # "Falar na Alexa"
        post :ask, on: :member, to: "asks#create" # card "Perguntar à casa" do painel
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
    end
  end
end
