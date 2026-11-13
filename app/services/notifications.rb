# Notificações com menos ruído (docs/push.md, "Menos ruído"): o que cada
# pessoa e a casa escolhem para o aviso que já existe (`Notification`,
# `Notifier`). Tudo dado, nada de regra por canal:
#
# - **Nível** = `data["priority"]` (normal / high = importante / critical).
#   Crítico fura o silêncio, o "silenciar" e nunca se junta a outro.
# - **Horário de silêncio** da pessoa (`users.dashboard_prefs["notifications"]["quiet"]`)
#   segura o push dela; o da casa (`tenants.settings["notifications"]["quiet"]`)
#   segura os canais da casa (fala nas Echo/players e mensageiros). Quem é de
#   quem: o canal declara `quiet_scope` (:person ou :house) no plugin de
#   `Notifier::Channels`; sem ele (no app), nunca cala. O aviso fica no app/web.
# - **Silenciar** uma automação/ponto por X horas (`mutes`, por pessoa):
#   `Notification#mute_key` ("automation:<id>", "point:<id>"); só tira o push.
# - **Juntar** avisos seguidos: `Notifications::Merge`.
# - **Resumo diário**: `Notifications::Digest`.
module Notifications
  USER_DEFAULTS = { "quiet" => { "enabled" => false, "from" => "22:00", "to" => "07:00" },
                    "digest" => { "enabled" => false, "at" => "08:00" },
                    "mute_hours" => 1, "mutes" => {} }.freeze
  HOUSE_DEFAULTS = { "quiet" => { "enabled" => false, "from" => "22:00", "to" => "07:00" }, "merge_s" => 120 }.freeze
  MUTE_HOURS = [ 1, 2, 4, 8, 24 ].freeze
  MERGE_CHOICES = [ 0, 60, 120, 300, 600, 1800 ].freeze
  LEVELS = %w[normal high critical].freeze
  TIME = /\A([01]\d|2[0-3]):[0-5]\d\z/

  module_function

  def user_prefs(user)
    own = user&.dashboard_prefs.to_h["notifications"].to_h
    USER_DEFAULTS.merge(own) { |_, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? a.merge(b) : b }
  end

  def house_prefs(tenant)
    own = tenant&.settings.to_h["notifications"].to_h
    HOUSE_DEFAULTS.merge(own) { |_, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? a.merge(b) : b }
  end

  def save_user!(user, prefs)
    user.update!(dashboard_prefs: user.dashboard_prefs.to_h.merge("notifications" => prefs))
  end

  def save_house!(tenant, prefs)
    tenant.update!(settings: tenant.settings.to_h.merge("notifications" => prefs))
  end

  # Janela padrão para juntar avisos seguidos (segundos; 0 = não junta).
  def merge_window(tenant) = house_prefs(tenant)["merge_s"].to_i.clamp(0, 6.hours.to_i)

  # Fuso: o do local do aviso, senão o primeiro local da instalação.
  def zone(tenant, site_id = nil)
    site = (Site.find_by(id: site_id) if site_id.present?) ||
           ActsAsTenant.without_tenant { Site.where(tenant_id: tenant&.id).order(:created_at).first }
    ActiveSupport::TimeZone[site&.timezone || Tenant::TIMEZONE]
  end

  def level(notification) = notification.data.to_h["priority"].presence_in(LEVELS) || "normal"
  def critical?(notification) = level(notification) == "critical"

  # "22:00" a "07:00" passa da meia-noite; de = até = o dia todo.
  def quiet_now?(window, now, zone)
    return false unless window.is_a?(Hash) && window["enabled"] == true && TIME.match?(window["from"].to_s) && TIME.match?(window["to"].to_s)

    t = now.in_time_zone(zone).strftime("%H:%M")
    from, to = window.values_at("from", "to")
    return true if from == to

    from < to ? (t >= from && t < to) : (t >= from || t < to)
  end

  # Push desta pessoa fica só no app? (silêncio dela ou "silenciado"; crítico fura).
  def hold_push?(user, notification, now = Time.current)
    return false if critical?(notification)

    prefs = user_prefs(user)
    quiet_now?(prefs["quiet"], now, zone(user.tenant, notification.data.to_h["site_id"])) || muted?(user, notification.mute_key, now)
  end

  # Canais da casa (fala, mensageiro) calados agora?
  def hold_house?(notification, now = Time.current)
    return false if notification.nil? || critical?(notification)

    tenant = ActsAsTenant.without_tenant { Tenant.find_by(id: notification.tenant_id) }
    quiet_now?(house_prefs(tenant)["quiet"], now, zone(tenant, notification.data.to_h["site_id"]))
  end

  # {chave → Time} só dos que ainda valem.
  def mutes(user, now = Time.current)
    user_prefs(user)["mutes"].to_h.filter_map { |k, v| (t = Time.zone.parse(v.to_s)) && t > now ? [ k, t ] : nil }.to_h
  rescue ArgumentError
    {}
  end

  def muted?(user, key, now = Time.current) = key.present? && mutes(user, now).key?(key)

  # Silencia `key` por `hours` (o rótulo vai junto para a lista). → Time (até quando).
  def mute!(user, key, hours, label: nil)
    raise ArgumentError, "mute key" if key.blank?

    hours = hours.to_i.clamp(1, 24 * 7)
    prefs = user_prefs(user)
    until_at = hours.hours.from_now
    list = mutes(user).transform_values(&:iso8601).merge(key => until_at.iso8601)
    labels = prefs["mute_labels"].to_h.slice(*list.keys).merge(key => label.to_s.truncate(120).presence).compact
    save_user!(user, prefs.merge("mutes" => list, "mute_labels" => labels))
    until_at
  end

  def unmute!(user, key)
    prefs = user_prefs(user)
    save_user!(user, prefs.merge("mutes" => prefs["mutes"].to_h.except(key), "mute_labels" => prefs["mute_labels"].to_h.except(key)))
  end

  # [{key, label, until}] para a tela e a API.
  def mute_list(user, now = Time.current)
    labels = user_prefs(user)["mute_labels"].to_h
    mutes(user, now).sort_by(&:last).map { |k, t| { "key" => k, "label" => labels[k].presence || k, "until" => t } }
  end
end
