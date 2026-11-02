module Push
  # O que um aviso leva ao aparelho de uma pessoa: título, corpo, ícone,
  # imagem (URL assinada e com validade), tag, prioridade, validade, fixo,
  # grupo, botões, progresso (0–100: notificação contínua que se atualiza
  # no lugar pela tag) e o que abrir ao tocar. `to_h(capabilities)` corta o que o
  # transporte não suporta (Notifier::FEATURES). Com botões, leva o token de
  # resposta dessa pessoa (Notification#action_token): a resposta pelo service
  # worker vale uma vez e só para ela.
  class Message
    ICON = "/icon-192.png".freeze
    BADGE = "/badge-96.png".freeze

    attr_reader :notification, :user

    def initialize(notification, user)
      @notification = notification
      @user = user
    end

    def data = notification.data
    def priority = data["priority"].presence_in(PRIORITIES.keys) || "normal"
    def critical? = priority == "critical"
    def ttl = data["ttl"].to_i.positive? ? data["ttl"].to_i : DEFAULT_TTL
    def urgency = priority == "normal" ? "normal" : "high"

    # Crítico nunca se junta a outro: sem tag própria, ganha uma única.
    def tag = data["tag"].presence || (critical? ? "critico-#{notification.id}" : nil)

    def to_h(capabilities = Notifier::FEATURES)
      can = ->(feature) { capabilities.include?(feature) }
      buttons = notification.actions if can.(:buttons)
      { "title" => notification.title, "body" => notification.body.to_s, "icon" => ICON, "badge" => BADGE,
        "image" => (notification.image_url if can.(:image)),
        "tag" => (tag if can.(:tag)), "renotify" => (true if can.(:tag) && tag),
        "requireInteraction" => ((can.(:priority) && critical?) || (can.(:sticky) && data["sticky"] == true) || nil),
        "actions" => buttons&.map { |a| { "action" => a["id"], "title" => a["title"] } }.presence,
        "data" => { "id" => notification.id, "url" => (can.(:link) && notification.open_url) || "/notificacoes",
                    "priority" => (priority if can.(:priority)), "group" => (data["group"].presence if can.(:group)),
                    "progress" => (data["progress"] if can.(:progress)),
                    "token" => (notification.action_token(user) if buttons.present?) }.compact }.compact
    end
  end
end
