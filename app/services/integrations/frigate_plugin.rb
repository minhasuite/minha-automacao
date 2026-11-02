module Integrations
  # Frigate (integ): câmeras com IA pelo servidor Frigate da casa (API e,
  # com broker, MQTT). Cada câmera vira aparelho com o ponto de detecção
  # (pessoa, veículo, animal, zona) e os sensores "na câmera agora"; o aviso
  # com quadro sai do `snapshot`. Lógica em ::Frigate.
  class FrigatePlugin < Plugin
    describe key: "frigate", title: "Frigate (câmeras com IA)", icon: "video-camera",
             description: "Detecção de pessoa, veículo e animal por câmera e por zona, com quadro e clipe, do Frigate da rede de casa. Vira gatilho \"Câmera detectou\"."
    texts "pt-BR" => { need_url: "Informe o endereço do Frigate (ex.: http://192.168.0.10:5000).", bad_url: "Endereço do Frigate inválido.", found: "%{n} câmera(s) no Frigate.", failed: "Não deu para falar com o Frigate: %{error}" },
          en: { title: "Frigate (AI cameras)", description: "Person, vehicle and animal detection per camera and zone, with snapshot and clip, from the Frigate on your home network. Becomes the \"Camera detected\" trigger.", need_url: "Enter the Frigate address (e.g. http://192.168.0.10:5000).", bad_url: "Invalid Frigate address.", found: "%{n} camera(s) in Frigate.", failed: "Couldn't reach Frigate: %{error}" },
          es: { title: "Frigate (cámaras con IA)", description: "Detección de personas, vehículos y animales por cámara y por zona, con imagen y clip, del Frigate de la red de casa. Se convierte en el disparador \"Cámara detectó\".", need_url: "Ingresa la dirección de Frigate (ej.: http://192.168.0.10:5000).", bad_url: "Dirección de Frigate no válida.", found: "%{n} cámara(s) en Frigate.", failed: "No se pudo comunicar con Frigate: %{error}" }

    def self.setup(site, form)
      return outcome(:form, alert: text(:need_url)) unless LanHttp.base(form[:url])

      login(new_integration(site, name: form[:name].to_s.squish.presence || "Frigate"), form)
    end

    def self.login(integration, form)
      url = LanHttp.base(form[:url].presence || integration.settings["url"]) or return outcome(:form, alert: text(:bad_url))
      topic = form[:topic].to_s.strip.delete_suffix("/").presence || integration.settings["topic"] || "frigate"
      integration.settings = integration.settings.merge("url" => url, "topic" => topic, "account" => URI(url).host)
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: text(:found, n: r[:found]))
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: text(:failed, error: e.message))
    end

    def self.inventory(integration) = Frigate.inventory(integration.settings["url"])
    def self.snapshot(point) = Frigate.snapshot(point)
    def self.event_snapshots? = true
  end
end
