module Integrations
  # DVR/NVR/câmera Hikvision pela ISAPI; as câmeras vão para o go2rtc.
  class HikvisionPlugin < Plugin
    describe key: "hikvision", title: "Câmeras / DVR", icon: "video-camera",
             description: "Gravador (DVR/NVR) ou câmera Hikvision da rede: endereço, usuário e senha. Acha os canais e mostra cada câmera, com ao vivo."
    texts "pt-BR" => { need: "Informe IP, usuário e senha do DVR.", found: "%{n} aparelho(s) lido(s) no DVR.", failed: "Não deu para ler o DVR: %{error}" },
          en: { title: "Cameras / DVR", description: "Hikvision recorder (DVR/NVR) or camera on your network: address, username and password. Finds the channels and shows each camera, with live view.", need: "Enter the DVR's IP, username and password.", found: "%{n} device(s) read from the DVR.", failed: "Couldn't read the DVR: %{error}" },
          es: { title: "Cámaras / DVR", description: "Grabador (DVR/NVR) o cámara Hikvision de la red: dirección, usuario y contraseña. Encuentra los canales y muestra cada cámara, en vivo.", need: "Ingresa la IP, el usuario y la contraseña del DVR.", found: "%{n} aparato(s) leído(s) en el DVR.", failed: "No se pudo leer el DVR: %{error}" }

    def self.setup(site, form)
      return outcome(:form, alert: text(:need)) if form[:host].blank? || form[:username].blank? || form[:password].blank?

      login(new_integration(site, name: "DVR #{form[:host].to_s.strip}"), form)
    end

    def self.login(integration, form)
      s = integration.settings
      host = form[:host].presence&.strip || s["host"]
      integration.settings = s.merge("host" => host, "account" => host, "http_port" => form[:http_port].presence || s["http_port"],
                                     "username" => form[:username].presence || s["username"]).compact
      integration.credentials = integration.secrets.merge("password" => form[:password]).to_json if form[:password].present?
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: text(:found, n: r[:found]))
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: text(:failed, error: e.message))
    end

    def self.inventory(integration) = Isapi.inventory(integration)

    # A câmera adotada usa a senha do DVR (o go2rtc monta a URL RTSP com ela).
    def self.device_secret(integration, _entry) = integration.secrets["password"]
  end
end
