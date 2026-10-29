# Casa virtual com os pontos das automações reais do HA (spec/fixtures/automations).
module AutomationHelpers
  CASA_POINTS = {
    "sala.camera_movimento" => { capability: "motion", value: false },
    "cozinha.iluminacao" => {}, "cozinha.sala_jantar" => {}, "sala.sala_estar" => {}, "sala.sala_tv" => {}, "cozinha.pendentes" => {},
    "garagem.sensor_portao" => { capability: "contact", value: false },
    "garagem.portao_eletronico" => { capability: "gate", value: "closed", options: %w[open closed], risk: "critical" },
    "cozinha.switch_cena" => {},
    "eva.bateria" => { capability: "measure", value: 80, unit: "%" },
    "eva.alerta_reconhecido" => {}, "eva.carregando" => { capability: "contact" },
    "cozinha.hub_zigbee" => { capability: "problem" }
  }.freeze

  def casa_points(site, device)
    CASA_POINTS.to_h do |key, attrs|
      [ key, create(:point, device: device, site: site, key: key, name: key.split(".").last.humanize, value: false, **attrs) ]
    end
  end

  def ha_fixture(name) = JSON.parse(Rails.root.join("spec/fixtures/automations/#{name}.json").read)

  # Automação publicada e ligada a partir de uma fixture.
  def ha_automation(site, name, **attrs)
    fx = ha_fixture(name)
    a = Automation.create!(site: site, name: fx["ha"], mode: fx["mode"], **attrs)
    a.publish!(fx["definition"])
    a.update!(enabled: true)
    a
  end
end

RSpec.configure { |c| c.include AutomationHelpers }
