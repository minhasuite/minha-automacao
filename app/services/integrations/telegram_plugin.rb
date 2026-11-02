module Integrations
  # Telegram (Pacote 4): o bot da própria pessoa (token do @BotFather,
  # cifrado) e a conversa (chat id) achada pelo `getUpdates` ("Achar meu
  # chat": a pessoa manda uma mensagem ao bot antes). Vira o canal de aviso
  # `messenger:<id>` (Notifier::Channels::Messenger): texto, foto do aviso e
  # botões (teclado embutido) ligados ao gatilho "Resposta de aviso".
  #
  # Respostas: por padrão o worker lê o `getUpdates` em espera longa
  # (`listen`, TELEGRAM_LISTENER=off desliga), porque o servidor de casa pode
  # não ter endereço público. Com "Receber por webhook" (precisa de
  # APP_HOST com https), o Telegram chama `POST /mensageiros/:id` com o
  # cabeçalho secreto e a leitura do worker para.
  class TelegramPlugin < Plugin
    API = "https://api.telegram.org".freeze
    POLL_TIMEOUT = 20

    describe key: "telegram", title: "Telegram", icon: "speakerphone",
             description: "Avisos no Telegram pelo seu bot: texto, foto da câmera e botões que respondem às automações."
    texts "pt-BR" => { need_token: "Cole o token do seu bot (do @BotFather).", need_token_short: "Cole o token do seu bot.", bot_connected: "Bot @%{bot} conectado. Agora ache o seu chat.", ready: "Telegram pronto: use \"%{name}\" nos avisos.", refused: "O Telegram recusou: %{error}", need_chat: "Ache o seu chat antes do teste.", test_text: "Teste do Minha Automação: os avisos chegam aqui.", test_sent: "Mensagem de teste enviada.", test_failed: "O teste falhou: %{error}", webhook_host: "Webhook precisa do endereço público (APP_HOST).", no_chat: "Sem chat: use Achar meu chat." },
          en: { title: "Telegram", description: "Alerts in Telegram through your bot: text, camera snapshot and buttons that answer automations.", need_token: "Paste your bot's token (from @BotFather).", need_token_short: "Paste your bot's token.", bot_connected: "Bot @%{bot} connected. Now find your chat.", ready: "Telegram ready: use \"%{name}\" in alerts.", refused: "Telegram refused: %{error}", need_chat: "Find your chat before testing.", test_text: "Minha Automação test: alerts will arrive here.", test_sent: "Test message sent.", test_failed: "The test failed: %{error}", webhook_host: "The webhook needs the public address (APP_HOST).", no_chat: "No chat: use Find my chat." },
          es: { title: "Telegram", description: "Avisos en Telegram por tu bot: texto, foto de la cámara y botones que responden a las automatizaciones.", need_token: "Pega el token de tu bot (de @BotFather).", need_token_short: "Pega el token de tu bot.", bot_connected: "Bot @%{bot} conectado. Ahora encuentra tu chat.", ready: "Telegram listo: usa \"%{name}\" en los avisos.", refused: "Telegram lo rechazó: %{error}", need_chat: "Encuentra tu chat antes de la prueba.", test_text: "Prueba de Minha Automação: los avisos llegan aquí.", test_sent: "Mensaje de prueba enviado.", test_failed: "La prueba falló: %{error}", webhook_host: "El webhook necesita la dirección pública (APP_HOST).", no_chat: "Sin chat: usa Encontrar mi chat." }

    def self.setup(site, form)
      integration = new_integration(site, name: form[:name].presence || title, poll_s: 0)
      configure(integration, form) or return outcome(:form, alert: text(:need_token))
      integration.save!
      check(integration)
    end

    def self.login(integration, form)
      configure(integration, form) or return outcome(:connect, integration: integration, alert: text(:need_token_short))
      integration.save!
      return test!(integration) if form[:test].present?

      check(integration)
    end

    def self.configure(integration, form)
      settings = integration.settings.merge("user_id" => integration.settings["user_id"] || Current.user&.id)
      settings["chat_id"] = form[:chat_id].to_s.strip.presence if form.key?(:chat_id)
      settings["webhook"] = ActiveModel::Type::Boolean.new.cast(form[:webhook]) == true if form.key?(:webhook)
      integration.settings = settings.compact
      integration.credentials = integration.secrets.merge("token" => form[:token].to_s.strip).to_json if form[:token].present?
      integration.secrets["token"].present?
    end

    # Testa o token (getMe), liga ou desliga o webhook e diz o próximo passo.
    def self.check(integration)
      sync!(integration)
      return outcome(:connect, integration: integration, notice: text(:bot_connected, bot: integration.account)) if integration.settings["chat_id"].blank?

      outcome(:index, notice: text(:ready, name: "#{integration.plugin.title}: #{integration.name}"))
    rescue Integrations::Error => e
      outcome(:connect, integration: integration, alert: text(:refused, error: e.message))
    end

    def self.test!(integration)
      return outcome(:connect, integration: integration, alert: text(:need_chat)) if integration.settings["chat_id"].blank?

      call(integration, "sendMessage", "chat_id" => integration.settings["chat_id"], "text" => text(:test_text))
      outcome(:connect, integration: integration, notice: text(:test_sent))
    rescue Integrations::Error => e
      outcome(:connect, integration: integration, alert: text(:test_failed, error: e.message))
    end

    def self.custom_sync? = true

    def self.sync!(integration)
      me = call(integration, "getMe")
      integration.settings = integration.settings.merge("account" => me["username"])
      integration.save!
      webhook!(integration)
      integration.ok!
      { found: 0, fresh: 0, removed: 0, keys: 0 }
    rescue Integrations::Error => e
      integration.error!(e)
      raise
    end

    # Webhook ligado: setWebhook com segredo próprio; desligado: deleteWebhook (o worker lê).
    def self.webhook!(integration)
      return call(integration, "deleteWebhook") unless integration.settings["webhook"]
      raise Integrations::Error, text(:webhook_host) if ENV["APP_HOST"].blank?

      secret = integration.secrets["webhook_secret"].presence || SecureRandom.hex(24)
      integration.merge_secrets!("webhook_secret" => secret)
      call(integration, "setWebhook", "url" => Rails.application.routes.url_helpers.messenger_webhook_url(integration, host: ENV["APP_HOST"], protocol: "https"),
                                      "secret_token" => secret, "allowed_updates" => [ "callback_query" ].to_json)
    end

    # "Achar meu chat": conversas que mandaram mensagem ao bot (getUpdates sem confirmar).
    def self.connect_locals(integration, params)
      return {} unless params[:find].present? && integration.secrets["token"].present?

      updates = call(integration, "getUpdates", "timeout" => 0, "allowed_updates" => [ "message" ].to_json)
      chats = Array(updates).filter_map { |u| u.dig("message", "chat") }.uniq { |c| c["id"] }
      { chats: chats.map { |c| { "id" => c["id"].to_s, "name" => c["title"].presence || [ c["first_name"], c["last_name"] ].compact.join(" ").presence || c["username"].to_s } }, searched: true }
    end

    def self.messenger_capabilities = %i[text buttons image link]

    def self.send_message(integration, notification)
      chat = integration.settings["chat_id"].presence or raise Integrations::Error, text(:no_chat)
      text = Notifier::Channels::Messenger.text(notification)
      buttons = Notifier::Channels::Messenger.buttons(notification)
      markup = { "inline_keyboard" => [ buttons.map { |ref, title| { "text" => title, "callback_data" => ref } } ] }.to_json if buttons.any?
      if (img = Notifier::Channels::Messenger.image(notification))
        body, type = Notifier::Channels::Messenger.multipart({ "chat_id" => chat, "caption" => text.truncate(1000), "reply_markup" => markup,
                                                               "photo" => [ img[0], img[1], "aviso.jpg" ] }.compact)
        post(integration, "sendPhoto", body, type)
      else
        call(integration, "sendMessage", { "chat_id" => chat, "text" => text.truncate(4000), "reply_markup" => markup }.compact)
      end
    end

    # Atualização do Telegram (webhook ou leitura): só o botão tocado na conversa configurada conta.
    def self.handle_update(integration, update)
      cb = update["callback_query"] or return
      return unless cb.dig("message", "chat", "id").to_s == integration.settings["chat_id"].to_s

      result = Notifier::Channels::Messenger.respond(integration, cb["data"])
      text = { ok: "Resposta registrada.", taken: "Este aviso já foi respondido." }.fetch(result, "Aviso não encontrado.")
      call(integration, "answerCallbackQuery", "callback_query_id" => cb["id"], "text" => text)
      return unless result == :ok

      call(integration, "editMessageReplyMarkup", "chat_id" => integration.settings["chat_id"], "message_id" => cb.dig("message", "message_id"),
                                                  "reply_markup" => { "inline_keyboard" => [] }.to_json)
    end

    # POST /mensageiros/:id: só com o cabeçalho secreto do setWebhook.
    def self.webhook(integration, request)
      secret = integration.secrets["webhook_secret"].to_s
      given = request.headers["X-Telegram-Bot-Api-Secret-Token"].to_s
      return [ 403, "" ] unless request.post? && secret.present? && ActiveSupport::SecurityUtils.secure_compare(secret, given)

      handle_update(integration, JSON.parse(request.raw_post))
      [ 200, "" ]
    rescue JSON::ParserError
      [ 400, "" ]
    end

    # Leitura no worker (sem webhook): espera longa no getUpdates, confirma pelo offset.
    def self.poll!(integration, timeout: POLL_TIMEOUT)
      offset = integration.settings["offset"]
      updates = call(integration, "getUpdates", { "offset" => offset, "timeout" => timeout, "allowed_updates" => [ "callback_query" ].to_json }.compact, timeout + 10)
      Array(updates).each do |u|
        handle_update(integration, u)
        integration.update_columns(settings: integration.settings.merge("offset" => u["update_id"].to_i + 1))
      end
    end

    def self.pollable = Integration.where(driver: driver).where("settings->>'chat_id' IS NOT NULL").where("COALESCE(settings->>'webhook', 'false') = 'false'")

    def self.listen
      return if @listener&.alive?

      @listener = Thread.new do
        loop do
          ids = Rails.application.executor.wrap { ActsAsTenant.without_tenant { pollable.pluck(:id) } }
          sleep 30 if ids.empty?
          ids.each { |id| listen_once(id, timeout: ids.one? ? POLL_TIMEOUT : 1) }
        rescue StandardError => e
          Rails.error.report(e, handled: true)
          sleep 30
        end
      end
    end

    def self.listen_once(id, timeout:)
      Rails.application.executor.wrap do
        integration = ActsAsTenant.without_tenant { Integration.find_by(id: id) } or return
        ActsAsTenant.with_tenant(integration.tenant) { poll!(integration, timeout: timeout) }
      end
    rescue Integrations::Error => e
      Rails.logger.warn("[telegram] #{id}: #{e.message}")
      sleep 10
    end

    def self.call(integration, method, params = {}, timeout = 15)
      post(integration, method, params.to_json, "application/json", timeout)
    end

    # O token vai no caminho: nunca aparece em erro nem em log.
    def self.post(integration, method, body, type, timeout = 30)
      token = integration.secrets["token"].to_s
      res = SafeHttp.request("POST", "#{API}/bot#{token}/#{method}", headers: { "Content-Type" => type }, body: body, timeout: timeout)
      data = JSON.parse(res.body) rescue {} # rubocop:disable Style/RescueModifier
      raise Integrations.auth(Integrations::Error.new("token recusado")) if res.status == 401
      raise Integrations::Error, data["description"].to_s.presence || "HTTP #{res.status}" unless data["ok"]

      data["result"]
    rescue SafeHttp::Error => e
      raise Integrations::Error, e.message.gsub(token, "***").truncate(120)
    end
  end
end
