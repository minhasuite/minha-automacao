# Script exposto como capacidade `script` (F8f): cada script do local tem um
# ponto no dispositivo virtual "Scripts" (`external_id: "scripts"`, fora da
# lista de dispositivos), com o comando `run`. Por ser ponto, o painel (tile
# com "Executar"), a API de pontos, o papel x risco e, depois, a Alexa (F9)
# funcionam sem código novo. O risco do ponto é o dos pontos que a versão
# publicada comanda.
module Scripts
  DEVICE_ID = "scripts".freeze

  module_function

  def device(site) = site.devices.find_or_create_by!(driver: "virtual", external_id: DEVICE_ID) { |d| d.name = "Scripts" }

  def point_for(script) = Point.where(site_id: script.site_id, capability: "script").find_by("points.address->>'script_id' = ?", script.id)

  def sync!(script)
    point = point_for(script) || device(script.site).points.new(site: script.site, capability: "script", history: "none",
                                                               address: { "script_id" => script.id })
    point.name = script.name
    point.icon = script.icon.presence_in(HelperTypes::ICONS)
    point.writable = true
    point.risk = script.published? ? script.max_risk(script.definition) : "normal"
    point.key = Integrations.unique_key(script.site, point.device, script.name) if point.key.blank?
    point.save! if point.changed?
  end

  def remove!(script) = point_for(script)&.destroy!

  # Driver virtual, comando `run` (valor opcional = {campo => valor}).
  def execute(point, value)
    script = Automation.find_by(id: point.address["script_id"], kind: "script") or raise invalid(I18n.t("automations.scripts.removed"))
    raise invalid(I18n.t("automations.scripts.unpublished")) unless script.published?

    run = script.run_script!(script.field_values(value.is_a?(Hash) ? value : {}), title: "Executar (#{Current.user&.name || 'painel'})", user: Current.user)
    raise invalid(I18n.t("automations.scripts.running", mode: script.mode_label.split(" (").first.downcase)) unless run
    raise invalid("#{script.name}: #{run.error}") if run.status == "failed"

    run
  rescue ArgumentError => e
    raise invalid(e.message.upcase_first)
  end

  def invalid(message) = Points::Command::Error.new(:invalid_value, message)
end
