module Integrations
  # Frigate (integ): câmeras com IA pelo servidor Frigate da casa (API e,
  # com broker, MQTT). Cada câmera vira aparelho com o ponto de detecção
  # (pessoa, veículo, animal, zona) e os sensores "na câmera agora"; o aviso
  # com quadro sai do `snapshot`. Lógica em ::Frigate.
  class FrigatePlugin < Plugin
    describe key: "frigate", title: "Frigate (câmeras com IA)", icon: "video-camera",
             description: "Detecção de pessoa, veículo e animal por câmera e por zona, com quadro e clipe, do Frigate da rede de casa. Vira gatilho \"Câmera detectou\"."

    def self.setup(site, form)
      return outcome(:form, alert: "Informe o endereço do Frigate (ex.: http://192.168.0.10:5000).") unless LanHttp.base(form[:url])

      login(new_integration(site, name: form[:name].to_s.squish.presence || "Frigate"), form)
    end

    def self.login(integration, form)
      url = LanHttp.base(form[:url].presence || integration.settings["url"]) or return outcome(:form, alert: "Endereço do Frigate inválido.")
      topic = form[:topic].to_s.strip.delete_suffix("/").presence || integration.settings["topic"] || "frigate"
      integration.settings = integration.settings.merge("url" => url, "topic" => topic, "account" => URI(url).host)
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: "#{r[:found]} câmera(s) no Frigate.")
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: "Não deu para falar com o Frigate: #{e.message}")
    end

    def self.inventory(integration) = Frigate.inventory(integration.settings["url"])
    def self.snapshot(point) = Frigate.snapshot(point)
    def self.event_snapshots? = true
  end
end
