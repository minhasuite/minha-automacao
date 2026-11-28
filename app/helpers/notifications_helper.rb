# Opções das telas de notificação (docs/push.md, "Menos ruído").
module NotificationsHelper
  def notification_level_choices = Notifications::LEVELS.map { |l| [ t("notifications.level.#{l}"), l ] }

  def notification_merge_choices(include_default: false)
    list = Notifications::MERGE_CHOICES.map { |s| [ s.zero? ? t("notifications.merge.off") : t("notifications.merge.window", count: s / 60), s ] }
    include_default ? [ [ t("notifications.merge.default"), "" ] ] + list : list
  end

  def mute_hours_choices = Notifications::MUTE_HOURS.map { |h| [ t("notifications.mute.hours", count: h), h ] }

  # Nível do aviso → nível da central do pacote (v1.9.2): "normal" fica sem.
  CENTER_LEVELS = { "high" => :warning, "critical" => :critical }.freeze

  # Âncora do aviso na central (o id que o Ss::NotificationCenterComponent põe em cada item, com id: "notificacoes").
  def notification_anchor(notification) = "notificacoes-item-#{notification.id}"

  # Um aviso da central (Ss::NotificationCenterComponent): o tipo dá o ícone (e o tom, sem nível), o nível dá o tom e o
  # selo; embaixo, a foto, os botões de resposta (ou quem respondeu), o "Ciente" do alerta aberto, o abrir e o silenciar.
  def notification_center_item(n, alerts = {})
    ico, tone = ApplicationHelper::NOTIFICATION_KINDS.fetch(n.kind, [ "bell", "is-muted" ])
    level = CENTER_LEVELS[n.level]
    { id: n.id, title: with_money(n.title), text: notification_center_text(n), at: n.created_at, unread: n.read_at.nil?,
      icon: icon(ico, ""), tone: (tone.delete_prefix("is-").to_sym unless level), level: level,
      href: read_notification_path(n), method: :patch,
      archive_href: archive_notification_path(n), archive_method: :post,
      unarchive_href: unarchive_notification_path(n), unarchive_method: :post,
      image: n.image_url, image_alt: t("automations.notifications.image"),
      actions: notification_center_actions(n, alerts[n.data.to_h["alert_id"]]),
      mute: (notification_center_mute(n) if n.mute_key) }
  end

  private

  def notification_center_text(n)
    extra = [
      (tag.span(t("notifications.merge.count", count: n.count), class: "ss-badge") if n.count > 1),
      (tag.span(safe_join([ icon("check", "size-3.5"), t("automations.notifications.answered", title: n.response_title, user: n.response["user"]) ]), class: "ss-badge ss-badge-success") if !n.actionable? && n.response)
    ].compact
    parts = [ (with_money(n.body) if n.body.present?), (tag.span(safe_join(extra, " "), class: "flex flex-wrap gap-1.5 mt-1.5") if extra.any?) ].compact
    safe_join(parts) if parts.any?
  end

  def notification_center_actions(n, alert)
    list = []
    if n.actionable?
      list += n.actions.map { |a| { label: a["title"], href: respond_notification_path(n), params: { action_id: a["id"] } } }
    end
    if alert && !alert.resolved? && !alert.acked? && SiteMembership.allowed?(alert.site.role_for(current_user), :command, risk: "sensitive")
      list << { label: t("automations.alerts.ack"), href: ack_alert_path(alert, back: "notificacoes"), method: :post, icon: icon("check", "") }
    end
    list << { label: t("automations.notifications.open"), href: n.open_url, method: :get, icon: icon("external-link", "") } if n.open_url
    list
  end

  def notification_center_mute(n)
    { label: t("notifications.mute.button"),
      options: Notifications::MUTE_HOURS.map { |h| { label: t("notifications.mute.for", count: h), href: mute_notification_path(n, hours: h) } } }
  end
end
