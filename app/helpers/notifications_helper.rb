# Opções das telas de notificação (docs/push.md, "Menos ruído").
module NotificationsHelper
  def notification_level_choices = Notifications::LEVELS.map { |l| [ t("notifications.level.#{l}"), l ] }

  def notification_merge_choices(include_default: false)
    list = Notifications::MERGE_CHOICES.map { |s| [ s.zero? ? t("notifications.merge.off") : t("notifications.merge.window", count: s / 60), s ] }
    include_default ? [ [ t("notifications.merge.default"), "" ] ] + list : list
  end

  def mute_hours_choices = Notifications::MUTE_HOURS.map { |h| [ t("notifications.mute.hours", count: h), h ] }
end
