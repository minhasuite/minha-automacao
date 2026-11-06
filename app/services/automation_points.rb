# Automação exposta como ponto liga/desliga (`onoff`, como o `automation.*`
# do HA): cada automação do local tem um ponto no dispositivo virtual
# "Automações" (`external_id: "automations"`, fora da lista de dispositivos)
# cujo valor é se ela está ligada. Por ser ponto, o painel (tile com o
# interruptor, na web e no app), a API de pontos e o papel x risco funcionam
# sem código novo; ligar exige a automação publicada.
module AutomationPoints
  DEVICE_ID = "automations".freeze

  module_function

  def device(site) = site.devices.find_or_create_by!(driver: "virtual", external_id: DEVICE_ID) { |d| d.name = "Automações" }

  def point_for(automation) = Point.where(site_id: automation.site_id, capability: "onoff").find_by("points.address->>'automation_id' = ?", automation.id)

  def automation?(point) = point.address.is_a?(Hash) && point.address["automation_id"].present?

  def sync!(automation)
    point = point_for(automation) || device(automation.site).points.new(site: automation.site, capability: "onoff", history: "on_change",
                                                                       address: { "automation_id" => automation.id })
    point.name = automation.name.to_s.first(120)
    point.writable = true
    point.key = Integrations.unique_key(automation.site, point.device, automation.name) if point.key.blank?
    point.save! if point.changed?
    point.report!(automation.enabled) unless point.value == automation.enabled && point.quality == "good"
    point
  end

  def remove!(automation) = point_for(automation)&.destroy!

  # Driver virtual: on/off/toggle liga ou desliga a automação; "run" roda agora a versão publicada, sem as
  # condições (o "Executar agora" da tela e o automation.trigger do HA).
  def execute(point, command, value)
    automation = Automation.find_by(id: point.address["automation_id"], kind: "automation") or raise invalid(I18n.t("automations.points.removed"))
    return run!(automation) if command == "run"

    on = Points::Command.new(point, command, value).new_value
    raise invalid(I18n.t("automations.points.unpublished")) if on && !automation.published?

    automation.update!(enabled: on)
  end

  def run!(automation)
    raise invalid(I18n.t("automations.points.unpublished")) unless automation.published?

    user = Current.user
    automation.fire!({ "type" => "manual", "title" => I18n.t("automations.points.run_title", name: user&.name.presence || "painel"),
                       "user_id" => user&.id }.compact, skip_conditions: true)
  end

  def invalid(message) = Points::Command::Error.new(:invalid_value, message)
end
