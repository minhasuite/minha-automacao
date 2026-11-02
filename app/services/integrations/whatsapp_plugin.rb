module Integrations
  # WhatsApp pela API oficial (WhatsApp Cloud API da Meta, Pacote 4): o token
  # e o id do número da conta da própria pessoa (cifrados) e o número que
  # recebe. Vira o canal `messenger:<id>`: texto, foto do aviso (enviada para
  # a Meta como mídia) e até 3 botões de resposta.
  #
  # A Meta só deixa mandar mensagem livre até 24 h depois da última mensagem
  # da pessoa para o número; fora disso, só modelo aprovado. Com "Modelo"
  # preenchido o aviso vai pelo modelo, com o texto no parâmetro {{1}} (sem
  # foto nem botões). Respostas dos botões: webhook da Meta em
  # `/mensageiros/:id` (GET com o token de verificação; POST assinado com o
  # segredo do app, `X-Hub-Signature-256`).
  class WhatsappPlugin < Plugin
    API = "https://graph.facebook.com/v21.0".freeze
    SECRETS = %w[token app_secret].freeze

    describe key: "whatsapp", title: "WhatsApp (API oficial)", icon: "device-mobile",
             description: "Avisos no WhatsApp pela API oficial da Meta, com a sua conta: texto, foto e botões de resposta."
    texts "pt-BR" => { required: "Informe o token, o id do número (Phone number ID) e o número que recebe os avisos.", connected: "WhatsApp conectado. Mande o teste para conferir.", refused: "A Meta recusou: %{error}", test_text: "Teste do Minha Automação: os avisos chegam aqui.", test_sent: "Mensagem de teste enviada.", test_failed: "O teste falhou: %{error}" },
          en: { title: "WhatsApp (official API)", description: "Alerts in WhatsApp through Meta's official API, with your account: text, photo and reply buttons.", required: "Enter the token, the number id (Phone number ID) and the number that receives the alerts.", connected: "WhatsApp connected. Send the test to check it.", refused: "Meta refused: %{error}", test_text: "Minha Automação test: alerts will arrive here.", test_sent: "Test message sent.", test_failed: "The test failed: %{error}" },
          es: { title: "WhatsApp (API oficial)", description: "Avisos en WhatsApp por la API oficial de Meta, con tu cuenta: texto, foto y botones de respuesta.", required: "Ingresa el token, el id del número (Phone number ID) y el número que recibe los avisos.", connected: "WhatsApp conectado. Envía la prueba para verificarlo.", refused: "Meta lo rechazó: %{error}", test_text: "Prueba de Minha Automação: los avisos llegan aquí.", test_sent: "Mensaje de prueba enviado.", test_failed: "La prueba falló: %{error}" }

    def self.setup(site, form)
      integration = new_integration(site, name: form[:name].presence || "WhatsApp", poll_s: 0)
      configure(integration, form) or return outcome(:form, alert: required_alert)
      integration.save!
      check(integration)
    end

    def self.login(integration, form)
      configure(integration, form) or return outcome(:connect, integration: integration, alert: required_alert)
      integration.save!
      return test!(integration) if form[:test].present?

      check(integration)
    end

    def self.required_alert = text(:required)

    def self.configure(integration, form)
      s = integration.settings.merge("user_id" => integration.settings["user_id"] || Current.user&.id)
      %w[phone_id to template language].each { |k| s[k] = form[k].to_s.strip.presence if form.key?(k) }
      s["to"] = s["to"]&.delete("^0-9")
      s["account"] = s["to"] && "+#{s['to']}"
      integration.settings = s.compact
      new_secrets = SECRETS.to_h { |k| [ k, form[k].to_s.strip ] }.compact_blank
      new_secrets["verify_token"] = SecureRandom.hex(16) if integration.secrets["verify_token"].blank?
      integration.credentials = integration.secrets.merge(new_secrets).to_json
      integration.secrets["token"].present? && s["phone_id"].present? && s["to"].present?
    end

    def self.check(integration)
      sync!(integration)
      outcome(:connect, integration: integration, notice: text(:connected))
    rescue Integrations::Error => e
      outcome(:connect, integration: integration, alert: text(:refused, error: e.message))
    end

    def self.test!(integration)
      send_text(integration, text(:test_text))
      outcome(:connect, integration: integration, notice: text(:test_sent))
    rescue Integrations::Error => e
      outcome(:connect, integration: integration, alert: text(:test_failed, error: e.message))
    end

    def self.custom_sync? = true

    # "Testar": lê o número (GET /<phone_id>), sem mandar nada.
    def self.sync!(integration)
      request(integration, "GET", integration.settings["phone_id"])
      integration.ok!
      { found: 0, fresh: 0, removed: 0, keys: 0 }
    rescue Integrations::Error => e
      integration.error!(e)
      raise
    end

    def self.messenger_capabilities = %i[text buttons image link]

    def self.send_message(integration, notification)
      text = Notifier::Channels::Messenger.text(notification)
      return send_template(integration, text) if integration.settings["template"].present?

      img = Notifier::Channels::Messenger.image(notification)
      media = img && upload(integration, img)
      buttons = Notifier::Channels::Messenger.buttons(notification)
      if buttons.any?
        interactive = { "type" => "button", "body" => { "text" => text.truncate(1024) },
                        "action" => { "buttons" => buttons.map { |ref, title| { "type" => "reply", "reply" => { "id" => ref, "title" => title.truncate(20) } } } } }
        interactive["header"] = { "type" => "image", "image" => { "id" => media } } if media
        message(integration, "interactive" => interactive)
      elsif media
        message(integration, "image" => { "id" => media, "caption" => text.truncate(1024) })
      else
        send_text(integration, text)
      end
    end

    def self.send_text(integration, text) = message(integration, "text" => { "body" => text.truncate(4096) })

    def self.send_template(integration, text)
      s = integration.settings
      message(integration, "template" => { "name" => s["template"], "language" => { "code" => s["language"].presence || "pt_BR" },
                                           "components" => [ { "type" => "body", "parameters" => [ { "type" => "text", "text" => text.truncate(1000) } ] } ] })
    end

    def self.message(integration, payload)
      type = payload.keys.first
      request(integration, "POST", "#{integration.settings['phone_id']}/messages",
              { "messaging_product" => "whatsapp", "to" => integration.settings["to"], "type" => type }.merge(payload).to_json, "application/json")
    end

    # Foto do aviso → mídia da Meta (id).
    def self.upload(integration, (bytes, type))
      body, ctype = Notifier::Channels::Messenger.multipart("messaging_product" => "whatsapp", "type" => type, "file" => [ bytes, type, "aviso.jpg" ])
      request(integration, "POST", "#{integration.settings['phone_id']}/media", body, ctype)["id"]
    end

    def self.request(integration, method, path, body = nil, type = nil)
      headers = { "Authorization" => "Bearer #{integration.secrets['token']}" }
      headers["Content-Type"] = type if type
      res = SafeHttp.request(method, "#{API}/#{path}", headers: headers, body: body, timeout: 30)
      data = JSON.parse(res.body) rescue {} # rubocop:disable Style/RescueModifier
      raise Integrations.auth(Integrations::Error.new("token recusado")) if res.status == 401
      raise Integrations::Error, data.dig("error", "message").to_s.truncate(150).presence || "HTTP #{res.status}" unless res.status.between?(200, 299)

      data
    rescue SafeHttp::Error => e
      raise Integrations::Error, e.message.truncate(120)
    end

    # Webhook da Meta: GET = verificação; POST = mensagens (só com a assinatura do app).
    def self.webhook(integration, request)
      return verify(integration, request.query_parameters) unless request.post?

      secret = integration.secrets["app_secret"].to_s
      given = request.headers["X-Hub-Signature-256"].to_s
      expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, request.raw_post)}"
      return [ 403, "" ] unless secret.present? && ActiveSupport::SecurityUtils.secure_compare(expected, given)

      JSON.parse(request.raw_post).fetch("entry", []).each do |entry|
        Array(entry["changes"]).flat_map { |c| Array(c.dig("value", "messages")) }.each do |m|
          ref = m.dig("interactive", "button_reply", "id") or next
          Notifier::Channels::Messenger.respond(integration, ref) if m["from"].to_s == integration.settings["to"].to_s
        end
      end
      [ 200, "" ]
    rescue JSON::ParserError
      [ 400, "" ]
    end

    def self.verify(integration, q)
      token = integration.secrets["verify_token"].to_s
      ok = q["hub.mode"] == "subscribe" && token.present? && ActiveSupport::SecurityUtils.secure_compare(token, q["hub.verify_token"].to_s)
      ok ? [ 200, q["hub.challenge"].to_s ] : [ 403, "" ]
    end
  end
end
