module Integrations
  # Câmera avulsa de qualquer marca (Lote 3, G16): pelo endereço RTSP ou pelo
  # ONVIF (acha os perfis de vídeo e, se a câmera tiver eventos, o ponto de
  # movimento). Vira um aparelho `go2rtc` como os do DVR: o vídeo, o quadro e
  # o ao vivo seguem pelo go2rtc; o movimento ONVIF chega pelo Onvif::Listener.
  # Usuário e senha saem da URL na hora de salvar: a senha fica só nas
  # credenciais cifradas (e no aparelho adotado), nunca no endereço.
  class CameraPlugin < Plugin
    describe key: "camera", title: "Câmera RTSP / ONVIF", icon: "video-camera",
             description: "Qualquer câmera IP da rede: cole o endereço do vídeo ou informe o IP e ela é encontrada sozinha. Imagem, ao vivo e aviso de movimento."

    SCHEMES = %w[rtsp rtsps].freeze

    def self.setup(site, form)
      settings = settings_from(form) or return outcome(:form, alert: form_error(form))

      login(new_integration(site, name: form[:name].to_s.squish.presence || "Câmera #{settings['host']}"), form, settings)
    end

    def self.login(integration, form, settings = nil)
      settings ||= settings_from(form, integration.settings) or return outcome(:connect, integration: integration, alert: form_error(form))
      password = form[:password].presence || url_password(form[:url])
      integration.settings = integration.settings.slice("auth_error").merge(settings).merge("name" => integration.name)
      integration.credentials = integration.secrets.merge("password" => password).to_json if password
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: "#{r[:found]} câmera(s) lida(s).")
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: "Não deu para ler a câmera: #{e.message}")
    end

    # Formulário → settings (sem senha) ou nil se faltar algo.
    def self.settings_from(form, current = {})
      user = form[:username].to_s.strip.presence
      mode = form[:mode].presence || current["mode"] || "rtsp"
      return onvif_settings(form, current, user) if mode == "onvif"
      return current.merge({ "username" => user }.compact) if form[:url].blank? && current["mode"] == "rtsp" # Reconfigurar sem trocar a URL

      uri = parse(form[:url]) or return

      { "mode" => "rtsp", "scheme" => uri.scheme, "host" => uri.host, "port" => uri.port || 554, "path" => Onvif.path_of(uri),
        "username" => user || (CGI.unescape(uri.user) if uri.user) || current["username"], "account" => uri.host }.compact
    end

    def self.onvif_settings(form, current, user)
      host = form[:host].to_s.strip.presence || current["host"] or return
      { "mode" => "onvif", "host" => host, "onvif_port" => (form[:onvif_port].presence || current["onvif_port"] || 80).to_i,
        "username" => user || current["username"], "account" => host }.compact
    end

    def self.parse(url)
      uri = URI.parse(url.to_s.strip)
      uri if SCHEMES.include?(uri.scheme) && uri.host.present?
    rescue URI::InvalidURIError
      nil
    end

    def self.url_password(url) = (u = parse(url)) && u.password && CGI.unescape(u.password)

    def self.form_error(form) = form[:mode] == "onvif" ? "Informe o IP da câmera." : "Informe o endereço RTSP (rtsp://IP:porta/caminho)."

    def self.inventory(integration)
      s = integration.settings
      return [ Onvif.inventory(s, integration.secrets["password"]) ] if s["mode"] == "onvif"

      [ { "id" => "rtsp:#{s['host']}:#{s['port']}#{s['path']}", "kind" => "go2rtc", "name" => s["name"].presence || "Câmera #{s['host']}",
          "category" => "Câmera RTSP", "address" => { "scheme" => s["scheme"], "host" => s["host"], "port" => s["port"], "username" => s["username"] }.compact,
          "points" => [ { "name" => "Vídeo", "capability" => "stream", "history" => "none", "address" => { "path" => s["path"] } } ] } ]
    end

    # O aparelho adotado usa a senha da câmera (o go2rtc monta a URL com ela).
    def self.device_secret(integration, _entry) = integration.secrets["password"].presence
  end
end
