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

    # "Silenciar 1 h" (docs/push.md, "Menos ruído"): só com espaço (o Chrome
    # mostra 2 botões), algo a silenciar e fora do crítico.
    def mute_button
      return [] if critical? || notification.mute_key.nil? || notification.actions.size >= 2

      hours = Notifications.user_prefs(user)["mute_hours"].to_i.clamp(1, 168)
      title = I18n.with_locale(user.dashboard_prefs.to_h["locale"].presence_in(I18n.available_locales.map(&:to_s)) || I18n.locale) do
        I18n.t("notifications.mute.push_button", count: hours)
      end
      [ { "id" => Notification::MUTE_ACTION, "title" => title } ]
    end

    def to_h(capabilities = Notifier::FEATURES)
      can = ->(feature) { capabilities.include?(feature) }
      buttons = (notification.actions + mute_button) if can.(:buttons)
      { "title" => notification.title, "body" => notification.body.to_s, "icon" => ICON, "badge" => BADGE,
        "image" => (notification.image_url if can.(:image)),
        "tag" => (tag if can.(:tag)), "renotify" => (true if can.(:tag) && tag && !notification.data["merged"]),
        "requireInteraction" => ((can.(:priority) && critical?) || (can.(:sticky) && data["sticky"] == true) || nil),
        "actions" => buttons&.map { |a| { "action" => a["id"], "title" => a["title"] } }.presence,
        "data" => { "id" => notification.id, "url" => (can.(:link) && notification.open_url) || "/notificacoes",
                    "priority" => (priority if can.(:priority)), "group" => (data["group"].presence if can.(:group)), "count" => (notification.count if notification.count > 1),
                    "progress" => (data["progress"] if can.(:progress)),
                    "command" => data["command"].presence, # appweb D2: só o app lê
                    "token" => (notification.action_token(user) if buttons.present?) }.compact }.compact
    end
  end
end
