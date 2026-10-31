module Integrations
  # Gateway HTTP de mensagens (Pacote 4): qualquer serviço que manda
  # mensagem por um pedido HTTP (Evolution API, CallMeBot, ntfy, Gotify, o
  # seu próprio) vira canal de aviso sem código: endereço, método, cabeçalhos
  # e corpo em Liquid. Variáveis: `title`, `message`, `text` (título + corpo +
  # link), `url`, `image_url` (endereço assinado da foto, 7 dias),
  # `image_base64` (a foto em base64) e `buttons` (títulos); filtro `json`
  # para pôr texto dentro de JSON (`{{ text | json }}`). Endereço, cabeçalhos
  # e corpo ficam cifrados (levam chaves) e o pedido passa pelo SafeHttp
  # (servidor na rede de casa: libere o IP em Configurações → Sistema).
  class HttpMessengerPlugin < Plugin
    METHODS = %w[POST GET PUT].freeze
    FIELDS = %w[url headers body].freeze

    # Filtro `json` do corpo: texto → literal JSON com aspas.
    module JsonFilter
      def json(input) = input.to_json
    end

    describe key: "http_messenger", title: "Gateway HTTP de mensagens", icon: "share",
             description: "Avisos por qualquer serviço com API HTTP (Evolution API, CallMeBot, ntfy): endereço e corpo com variáveis."

    def self.setup(site, form)
      integration = new_integration(site, name: form[:name].presence || "Mensagens por HTTP", poll_s: 0)
      error = configure(integration, form) and return outcome(:form, alert: error)
      integration.save!
      outcome(:connect, integration: integration, notice: "Gateway salvo. Mande o teste para conferir.")
    end

    def self.login(integration, form)
      error = configure(integration, form) and return outcome(:connect, integration: integration, alert: error)
      integration.save!
      return outcome(:connect, integration: integration, notice: "Gateway salvo.") if form[:test].blank?

      send_message(integration, Notification.new(title: "Teste do Minha Automação", body: "Os avisos chegam aqui.", data: {}))
      integration.ok!
      outcome(:connect, integration: integration, notice: "Mensagem de teste enviada.")
    rescue Integrations::Error => e
      integration.error!(e)
      outcome(:connect, integration: integration, alert: "O teste falhou: #{e.message}")
    end

    # → texto do erro ou nil. Campo vazio no formulário = mantém o guardado.
    def self.configure(integration, form)
      method = form[:method].to_s.upcase.presence_in(METHODS) || integration.settings["method"] || "POST"
      integration.settings = integration.settings.merge("method" => method)
      given = FIELDS.to_h { |k| [ k, form[k].to_s.strip ] }.compact_blank
      integration.credentials = integration.secrets.merge(given).to_json
      s = integration.secrets
      return "Informe o endereço (http ou https)." unless s["url"].to_s.match?(%r{\Ahttps?://}i)

      integration.settings = integration.settings.merge("account" => (URI.parse(s["url"].split("{{").first).host rescue nil)) # rubocop:disable Style/RescueModifier
      FIELDS.each do |k|
        Liquid::Template.parse(s[k].to_s, error_mode: :strict)
      rescue Liquid::Error => e
        return "Erro no modelo (#{k}): #{e.message.truncate(100)}"
      end
      nil
    end

    def self.custom_sync? = true
    def self.sync!(integration) = { found: 0, fresh: 0, removed: 0, keys: 0 }.tap { integration.ok! }
    def self.messenger_capabilities = %i[text image link]

    def self.send_message(integration, notification)
      s = integration.secrets
      vars = variables(notification, [ s["url"], s["headers"], s["body"] ].join)
      render = ->(t) { Liquid::Template.parse(t.to_s, error_mode: :strict).render!(vars, { strict_filters: true, filters: [ JsonFilter ] }) }
      headers = render.(s["headers"]).lines.filter_map { |l| l.split(":", 2).map(&:strip) if l.include?(":") }.to_h
      body = render.(s["body"]).presence
      headers["Content-Type"] ||= body&.lstrip&.start_with?("{", "[") ? "application/json" : "text/plain; charset=utf-8" if body
      method = integration.settings["method"] || "POST"
      res = SafeHttp.request(method, render.(s["url"]).strip, headers: headers, body: (body unless method == "GET"), timeout: 20)
      raise Integrations::Error, "HTTP #{res.status}" unless res.status.between?(200, 299)

      res
    rescue SafeHttp::Error, Liquid::Error => e
      raise Integrations::Error, e.message.truncate(120)
    end

    def self.variables(n, templates)
      img = n.image_url
      img = "#{Notifier::Channels::Messenger.base_url}#{img}" if img&.start_with?("/")
      raw = Notifier::Channels::Messenger.image(n) if templates.include?("image_base64")
      url = n.open_url
      url = "#{Notifier::Channels::Messenger.base_url}#{url}" if url&.start_with?("/")
      { "title" => n.title.to_s, "message" => n.body.to_s, "text" => Notifier::Channels::Messenger.text(n), "url" => url.to_s,
        "image_url" => img.to_s, "image_base64" => raw ? Base64.strict_encode64(raw[0]) : "", "buttons" => n.actions.map { |a| a["title"] } }
    end
  end
end
