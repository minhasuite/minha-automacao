# Alerta aberto por uma AlertRule (ESQUEMA-V1 §4.5): a central com "ciente".
# `level` = etapas já avisadas. "Ciente" para o escalonamento (o alerta fica
# aberto até a condição sumir; regra sem auto_resolve fecha no ciente).
class Alert < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :site
  belongs_to :alert_rule
  belongs_to :point
  belongs_to :acked_by, class_name: "User", optional: true

  # Gatilho "alerta" das automações (F6).
  after_create_commit { Automations.safely { Automations::Triggers.alert(self, "open") } }
  after_update_commit do
    Automations.safely { Automations::Triggers.alert(self, "ack") } if saved_change_to_acked_at? && acked_at
    Automations.safely { Automations::Triggers.alert(self, "resolve") } if saved_change_to_resolved_at? && resolved_at
  end

  scope :active, -> { where(resolved_at: nil) }
  scope :recent, -> { order(opened_at: :desc) }

  def acked? = acked_at.present?
  def resolved? = resolved_at.present?

  # Agenda a etapa `level` (na hora se a espera for zero).
  def schedule_step
    steps = alert_rule.escalation
    wait = level < steps.size ? steps[level]["wait_s"] : alert_rule.repeat_s
    return unless wait
    return step!(level) if wait.zero?

    AlertStepJob.set(wait: wait.seconds).perform_later(id, level)
  end

  # Avisa a etapa `n` e agenda a próxima. Job repetido ou atrasado não avisa
  # duas vezes (só age se `n` for a próxima etapa).
  def step!(n)
    return if resolved? || acked? || n != level

    steps = alert_rule.escalation
    step = steps[n] || steps.last
    Shadow.for_site(site) { notify_step!(step, n) }
    update!(level: n + 1)
    schedule_step
  end

  def notify_step!(step, n)
    minutes = ((Time.current - (point.changed_at || opened_at)) / 60).floor
    Notifier.deliver!(step["channels"], kind: "alerta", title: alert_rule.name,
                                        body: I18n.t("automations.alerts.push_body", name: point.name, value: ApplicationController.helpers.point_value_text(point), minutes: minutes),
                                        data: { alert_id: id, point_id: point_id, site_id: site_id, severity: alert_rule.severity },
                                        dedup_key: "alert:#{id}:#{n}")
  rescue Shadow::Blocked
    nil
  end

  def ack!(user)
    update!(acked_by: user, acked_at: Time.current, resolved_at: (Time.current unless alert_rule.auto_resolve))
  end

  def resolve! = update!(resolved_at: Time.current)
end
