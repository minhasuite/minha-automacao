module Integrations
  # Câmera TP-Link Tapo (C100/C200/C310/C500… e TC7x). Uma integração por
  # câmera, como o ONVIF genérico, mas já sabendo o que a Tapo tem: ONVIF na
  # porta 2020 com a "conta da câmera" (criada no app Tapo), stream1 (alta) e
  # stream2 (baixa) pelo go2rtc, movimento por PullPoint no Onvif::Listener e
  # os recursos da família em config/device_maps/tapo.yml (PTZ, sirene,
  # alto-falante, holofote) no `address.supports` dos pontos de vídeo.
  #
  # Com a senha da nuvem (opcional): o vídeo principal ganha a fonte
  # `tapo://` do go2rtc (falar pelo alto-falante; o ONVIF da Tapo não tem
  # áudio de volta) e, com "Controlar pela API local" marcado, os pontos de
  # privacidade, LED, detecção de movimento e sirene (Tapo::Client).
  class TapoPlugin < LanPlugin
    describe key: "tapo", title: "Câmera Tapo (TP-Link)", icon: "video-camera",
             description: "Câmeras Tapo da rede de casa: vídeo alto e baixo, giro (PTZ), movimento, falar pelo alto-falante e, opcional, privacidade, LED e sirene."
    texts "pt-BR" => { need_account: "Informe a conta da câmera (usuário e senha criados no app Tapo em Configurações avançadas → Conta da câmera).",
                       no_onvif: "A câmera não respondeu no ONVIF (porta 2020): %{error}. Confira o IP, a conta da câmera e se o modelo tem RTSP (as de bateria e a campainha D230 não têm).",
                       no_rtsp: "Este modelo (%{model}) não tem RTSP/ONVIF: o vídeo só sai pela nuvem da TP-Link.",
                       no_control: "Controle local desligado nesta câmera." },
          en: { title: "Tapo camera (TP-Link)", description: "Tapo cameras on your home network: high and low video, pan/tilt (PTZ), motion, talk through the speaker and, optionally, privacy, LED and siren.",
                need_account: "Enter the camera account (user and password created in the Tapo app under Advanced settings → Camera account).",
                no_onvif: "The camera didn't answer on ONVIF (port 2020): %{error}. Check the IP, the camera account and whether the model has RTSP (battery models and the D230 doorbell don't).",
                no_rtsp: "This model (%{model}) has no RTSP/ONVIF: video only goes through the TP-Link cloud.",
                no_control: "Local control is off for this camera." },
          es: { title: "Cámara Tapo (TP-Link)", description: "Cámaras Tapo de la red de casa: video alto y bajo, giro (PTZ), movimiento, hablar por el altavoz y, opcional, privacidad, LED y sirena.",
                need_account: "Ingresa la cuenta de la cámara (usuario y contraseña creados en la app Tapo en Ajustes avanzados → Cuenta de la cámara).",
                no_onvif: "La cámara no respondió por ONVIF (puerto 2020): %{error}. Revisa la IP, la cuenta de la cámara y si el modelo tiene RTSP (las de batería y el timbre D230 no tienen).",
                no_rtsp: "Este modelo (%{model}) no tiene RTSP/ONVIF: el video solo sale por la nube de TP-Link.",
                no_control: "Control local apagado en esta cámara." }
    port 2020
    plain :username, :control
    secrets :password, :cloud_password
    # Os mesmos nomes que a câmera pede ao roteador no manifesto do tapo_control do HA (C200_xxxx, TC70_xxxx, D230_xxxx).
    dhcp({ hostname: "c[0-9][0-9][0-9]*_*" }, { hostname: "tc[0-9][0-9]*_*" }, { hostname: "d[0-9][0-9][0-9]*_*" })

    MAIN = "/stream1".freeze
    LOW = "/stream2".freeze

    class << self
      def probe(integration)
        s = integration.settings
        password = integration.secrets["password"]
        raise Integrations.auth(Integrations::Error.new(text(:need_account))) if s["username"].blank? || password.blank?

        entry = onvif_entry(integration, s, password)
        features = Tapo.preset(entry["model"])
        raise Integrations::Error, text(:no_rtsp, model: entry["model"]) if features["rtsp"] == false

        decorate(entry, integration, features)
      end

      def onvif_entry(integration, settings, password)
        Onvif.inventory({ "host" => settings["host"], "onvif_port" => port_of(integration), "username" => settings["username"], "name" => settings["name"] }, password)
      rescue Onvif::Error => e
        raise if e.is_a?(Integrations::AuthError)

        raise Integrations::Error, text(:no_onvif, error: e.message)
      end

      # Entrada do ONVIF → câmera Tapo: nomes dos vídeos, recursos do modelo,
      # lente tele, fonte de fala e os pontos de controle.
      def decorate(entry, integration, features)
        talk = features["two_way_audio"] && cloud_password(integration).present?
        streams = entry["points"].select { |p| p["capability"] == "stream" }
        main = streams.find { |p| p.dig("address", "path") == MAIN } || streams.first
        streams.each { |p| tune_stream(p, features, talk: talk && p.equal?(main)) }
        extra = Array(features["streams"]).reject { |x| streams.any? { |p| p.dig("address", "path") == x["path"] } }.map do |x|
          tune_stream({ "name" => text_for("points.#{x['name']}"), "capability" => "stream", "history" => "none", "writable" => true,
                        "address" => { "path" => x["path"] } }, features, talk: false)
        end
        controls = control?(integration) ? Tapo.control_points(features) : []
        entry.merge("id" => "tapo:#{integration.settings['host']}", "manufacturer" => "TP-Link", "category" => "Câmera Tapo",
                    "name" => integration.settings["name"].presence || "Tapo #{entry['model']}".strip,
                    "address" => entry["address"].merge("features" => features.slice("ptz", "siren", "two_way_audio", "spotlight")),
                    "points" => entry["points"] + extra + controls, "poll_s" => (300 if controls.any?)).compact
      end

      def tune_stream(point, features, talk:)
        a = point["address"] ||= {}
        point["name"] = text_for("points.high") if a["path"] == MAIN
        point["name"] = text_for("points.low") if a["path"] == LOW
        supports = Array(a["supports"]) | [ "record" ]
        supports |= [ "ptz" ] if features["ptz"]
        supports |= [ "play_media" ] if talk
        a["supports"] = supports
        a["talk"] = true if talk
        point
      end

      def text_for(key) = I18n.t("tapo.#{key}")

      def cloud_password(integration) = integration&.secrets&.dig("cloud_password").presence

      # Controle local: interruptor geral, caixa marcada e a senha da nuvem.
      def control?(integration) = Tapo.enabled? && integration.settings["control"] == "1" && cloud_password(integration).present?

      # O go2rtc monta o RTSP com a senha da conta da câmera (Drivers::Go2rtc.source).
      def device_secret(integration, _entry) = integration.secrets["password"].presence

      # Vídeo principal com fala: o go2rtc junta o RTSP (vídeo) e o tapo:// (áudio de volta).
      def extra_sources(point)
        cloud = cloud_password(point.device.integration)
        host = point.device.address["host"]
        return [] unless point.address["talk"] && cloud && host.present?

        [ "tapo://#{ERB::Util.url_encode(cloud)}@#{host}" ]
      end

      # Depois da varredura e da adoção: lê os controles (privacidade, LED…).
      def refresh(integration) = Drivers.refresh(integration)

      def control_points(device) = device.points.select { |p| p.address["tapo"].present? && !p.disabled }

      def camera_command(point, command, _value)
        key = point.address["tapo"] or raise Integrations::Error, "Ponto sem controle Tapo."
        integration = point.device.integration
        raise Integrations::Error, text(:no_control) unless integration && control?(integration)

        on = command == "toggle" ? point.value != true : command == "on"
        Tapo.write(Tapo.client(point.device.address["host"], cloud_password(integration)), key, on)
        point.report!(on)
      end

      def camera_poll(device)
        points = control_points(device)
        integration = device.integration
        return if points.empty? || integration.nil? || !control?(integration)

        values = Tapo.read(Tapo.client(device.address["host"], cloud_password(integration)), points.map { |p| p.address["tapo"] })
        device.update_columns(status: "online", last_seen_at: Time.current)
        points.each { |p| p.report!(values[p.address["tapo"]]) if values.key?(p.address["tapo"]) }
      end
    end
  end
end
