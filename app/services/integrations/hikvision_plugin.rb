module Integrations
  # DVR/NVR/câmera Hikvision pela ISAPI; as câmeras vão para o go2rtc.
  class HikvisionPlugin < Plugin
    describe key: "hikvision", title: "Câmeras / DVR", icon: "video-camera",
             description: "DVR, NVR ou câmera Hikvision na rede: IP, usuário e senha. Acha os canais e coloca as câmeras no go2rtc."

    def self.setup(site, form)
      return outcome(:form, alert: "Informe IP, usuário e senha do DVR.") if form[:host].blank? || form[:username].blank? || form[:password].blank?

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
      outcome(:found, integration: integration, notice: "#{r[:found]} aparelho(s) lido(s) no DVR.")
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: "Não deu para ler o DVR: #{e.message}")
    end

    def self.inventory(integration) = Isapi.inventory(integration)

    # A câmera adotada usa a senha do DVR (o go2rtc monta a URL RTSP com ela).
    def self.device_secret(integration, _entry) = integration.secrets["password"]
  end
end
