module Integrations
  # ntfy (app do catálogo ou o ntfy.sh): canal de aviso por push próprio,
  # sem Google. É um mensageiro (Notifier::Channels::Messenger): o plugin
  # responde a `send_message` e o canal `messenger:<id>` aparece sozinho nos
  # avisos. Tópico e token por integração; o token vai cifrado.
  #
  # Botões do aviso viram ações "http" do ntfy, que o celular manda para
  # `/mensageiros/:id` com um segredo próprio da integração (cabeçalho
  # X-MA-Token); só com o acesso externo (APP_HOST) ligado.
  class NtfyPlugin < SchemaPlugin
    describe key: "ntfy", title: "ntfy", icon: "bell",
             description: "Avisos por push no app ntfy (Android/iOS), pelo seu servidor ntfy ou pelo ntfy.sh, sem Google. Vira um canal nos avisos e alertas."
    texts "pt-BR" => { fields: { topic: "Tópico", priority: "Prioridade" }, hints: { url: "https://ntfy.sh ou http://192.168.0.10:8093", topic: "casa-avisos-x7k2 (difícil de adivinhar)" },
                       options: { priority: { min: "Mínima", low: "Baixa", default: "Normal", high: "Alta", urgent: "Urgente" } },
                       bad_topic: "Tópico inválido: use letras, números, - e _ (até 64).", ok: "ntfy pronto: escolha o canal nos avisos." },
          en: { title: "ntfy", description: "Push alerts on the ntfy app (Android/iOS), through your own ntfy server or ntfy.sh, without Google. Becomes a channel for alerts.",
                fields: { topic: "Topic", priority: "Priority" }, hints: { url: "https://ntfy.sh or http://192.168.0.10:8093", topic: "home-alerts-x7k2 (hard to guess)" },
                options: { priority: { min: "Minimum", low: "Low", default: "Normal", high: "High", urgent: "Urgent" } },
                bad_topic: "Invalid topic: use letters, numbers, - and _ (up to 64).", ok: "ntfy ready: pick the channel in your alerts." },
          es: { title: "ntfy", description: "Avisos por push en la app ntfy (Android/iOS), por tu servidor ntfy o ntfy.sh, sin Google. Se vuelve un canal en los avisos y alertas.",
                fields: { topic: "Tema", priority: "Prioridad" }, hints: { url: "https://ntfy.sh o http://192.168.0.10:8093", topic: "casa-avisos-x7k2 (difícil de adivinar)" },
                options: { priority: { min: "Mínima", low: "Baja", default: "Normal", high: "Alta", urgent: "Urgente" } },
                bad_topic: "Tema no válido: usa letras, números, - y _ (hasta 64).", ok: "ntfy listo: elige el canal en los avisos." }
    field :url, :url, default: "https://ntfy.sh"
    field :topic, required: true
    field :token, secret: true
    field :priority, :select, options: %w[min low default high urgent], default: "default"

    TOPIC = /\A[\w-]{1,64}\z/
    PRIORITY = { "min" => 1, "low" => 2, "default" => 3, "high" => 4, "urgent" => 5 }.freeze

    class << self
      def entries(_integration) = []
      def custom_sync? = true

      def sync!(integration)
        integration.ok!
        { found: 0, fresh: 0, removed: 0, keys: 0 }
      end

      def login(integration, form)
        return outcome(:form, alert: text(:bad_topic)) unless (form[:topic].presence || integration.settings["topic"]).to_s.strip.match?(TOPIC)

        o = super
        return o if o.alert

        # Segredo das respostas de botão (não é o token do ntfy; nunca vai para a tela).
        integration.update!(credentials: integration.secrets.merge("webhook_secret" => SecureRandom.hex(24)).to_json) if integration.secrets["webhook_secret"].blank?
        outcome(:index, notice: text(:ok))
      end

      # Corpo JSON do ntfy (publicar na raiz do servidor com `topic`).
      def payload(integration, n)
        base = Notifier::Channels::Messenger.base_url
        url = n.open_url
        url = "#{base}#{url}" if url&.start_with?("/")
        image = n.image_url
        image = "#{base}#{image}" if image&.start_with?("/")
        actions = (base.present? ? Notifier::Channels::Messenger.buttons(n).first(3) : []).map do |ref, title|
          { action: "http", label: title.to_s.first(40), url: "#{base}/mensageiros/#{integration.id}", method: "POST",
            headers: { "X-MA-Token" => integration.secrets["webhook_secret"].to_s }, body: ref, clear: true }
        end
        { topic: conf(integration, :topic), title: n.title.to_s.first(250), message: n.body.to_s.presence || n.title.to_s,
          priority: PRIORITY.fetch(conf(integration, :priority).to_s, 3), click: url.presence, attach: (image if image.to_s.start_with?("https://")),
          actions: actions.presence }.compact
      end

      def send_message(integration, notification)
        headers = { "Content-Type" => "application/json" }
        token = integration.secrets["token"].presence
        headers["Authorization"] = "Bearer #{token}" if token
        res = SafeHttp.request("POST", conf(integration, :url).to_s.chomp("/"), headers: headers, body: payload(integration, notification).to_json, timeout: 15)
        raise Integrations::Error, "ntfy respondeu #{res.status}." unless res.status.between?(200, 299)

        res
      rescue SafeHttp::Error => e
        raise Integrations::Error, "ntfy: #{e.message.truncate(120)}"
      end

      # Botão tocado no celular: a ação "http" do ntfy manda a referência no corpo.
      def webhook(integration, request)
        return [ 405, "" ] unless request.post?

        secret = integration.secrets["webhook_secret"].to_s
        return [ 403, "" ] unless secret.present? && ActiveSupport::SecurityUtils.secure_compare(secret, request.headers["X-MA-Token"].to_s)

        status = Notifier::Channels::Messenger.respond(integration, request.raw_post.to_s.strip)
        status == :invalid ? [ 404, "" ] : [ 200, status.to_s ]
      end
    end
  end
end
