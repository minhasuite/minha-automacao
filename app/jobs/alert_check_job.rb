# Fim da espera `for_s` de uma AlertRule: se o ponto não mudou desde então
# (mesmo `changed_at`), reavalia e abre o alerta.
class AlertCheckJob < ApplicationJob
  queue_as :default

  def perform(rule_id, changed_at)
    rule = ActsAsTenant.without_tenant { AlertRule.find_by(id: rule_id) } or return
    ActsAsTenant.with_tenant(rule.tenant) do
      rule.evaluate if rule.enabled && rule.point.changed_at&.iso8601(6) == changed_at
    end
  end
end
