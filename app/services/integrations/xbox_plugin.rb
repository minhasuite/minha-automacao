module Integrations
  # resto2 (grupo 9 #76; o `xbox` do HA): consoles Xbox da conta pela API do
  # Xbox Live (o SmartGlass na nuvem, xccs.xboxlive.com), com o app OAuth do
  # PRÓPRIO dono no Azure (OauthPlugin; o que criar está em docs/catalogo.md).
  # Token da Microsoft → token de usuário do Xbox Live → XSTS (guardado
  # cifrado até vencer); cabeçalho "XBL3.0 x=<uhs>;<token>". Liga, desliga,
  # volume, mudo, mídia, teclas do controle e abrir app/jogo; estado e o app
  # em foco. O console precisa de "Ligar rápido"/"Suspensão" e de "Permitir
  # aplicativos de controle remoto" (Configurações → Dispositivos → Recursos remotos).
  class XboxPlugin < OauthPlugin
    describe key: "xbox", title: "Xbox", icon: "desktop-computer",
             description: "Consoles Xbox da sua conta pelo Xbox Live: liga, desliga, volume, mídia, teclas do controle e abrir jogo ou app. Usa o seu próprio app no Azure."
    texts "pt-BR" => { points: { media: "Xbox", remote: "Controle" }, no_profile: "Esta conta Microsoft não tem perfil Xbox (crie em xbox.com).",
                       note: "No console: Configurações → Dispositivos e conexões → Recursos remotos → \"Permitir aplicativos de controle remoto\"." },
          en: { title: "Xbox", description: "Xbox consoles on your account through Xbox Live: power, volume, media, controller keys and opening a game or app. Uses your own Azure app.",
                points: { media: "Xbox", remote: "Controller" }, no_profile: "This Microsoft account has no Xbox profile (create one at xbox.com).",
                note: "On the console: Settings → Devices & connections → Remote features → \"Enable remote features\"." },
          es: { title: "Xbox", description: "Consolas Xbox de tu cuenta por Xbox Live: encender, apagar, volumen, multimedia, teclas del control y abrir juego o app. Usa tu propia app en Azure.",
                points: { media: "Xbox", remote: "Control" }, no_profile: "Esta cuenta Microsoft no tiene perfil Xbox (créalo en xbox.com).",
                note: "En la consola: Configuración → Dispositivos y conexiones → Funciones remotas → \"Habilitar funciones remotas\"." }
    oauth authorize: "https://login.live.com/oauth20_authorize.srf", token: "https://login.live.com/oauth20_token.srf",
          scope: "Xboxlive.signin Xboxlive.offline_access"

    USER_AUTH = "https://user.auth.xboxlive.com/user/authenticate".freeze
    XSTS = "https://xsts.auth.xboxlive.com/xsts/authorize".freeze
    API = "https://xccs.xboxlive.com".freeze
    NO_PROFILE = 2_148_916_233
    SUPPORTS = %w[on off pause resume next previous volume_up volume_down mute play_media].freeze
    BUTTONS = %w[Up Down Left Right A B X Y Nexus View Menu].freeze
    # comando → [tipo, comando do SmartGlass]
    COMMANDS = { "on" => %w[Power WakeUp], "off" => %w[Power TurnOff], "pause" => %w[Media Pause], "resume" => %w[Media Play],
                 "next" => %w[Media Next], "previous" => %w[Media Previous], "volume_up" => %w[Audio Volume], "volume_down" => %w[Audio Volume],
                 "play_media" => %w[Shell ActivateApplicationWithOneStoreProductId], "send" => %w[Shell InjectKey] }.freeze

    class << self
      def xsts(integration, force: false)
        s = integration.secrets
        return s.values_at("xsts", "uhs") if !force && s["xsts"].present? && s["xsts_until"].to_i > Time.current.to_i + 60

        user = auth_post(USER_AUTH, { RelyingParty: "http://auth.xboxlive.com", TokenType: "JWT",
                                      Properties: { AuthMethod: "RPS", SiteName: "user.auth.xboxlive.com", RpsTicket: "d=#{access_token(integration, force: force)}" } })
        x = auth_post(XSTS, { RelyingParty: "http://xboxlive.com", TokenType: "JWT", Properties: { UserTokens: [ user["Token"] ], SandboxId: "RETAIL" } })
        uhs = x.dig("DisplayClaims", "xui", 0, "uhs")
        until_at = (Time.zone.parse(x["NotAfter"].to_s) rescue nil)&.to_i || (Time.current.to_i + 3600) # rubocop:disable Style/RescueModifier
        integration.merge_secrets!("xsts" => x["Token"], "uhs" => uhs, "xsts_until" => until_at)
        [ x["Token"], uhs ]
      end

      def auth_post(url, body)
        res = SafeHttp.request("POST", url, headers: { "Content-Type" => "application/json", "Accept" => "application/json", "x-xbl-contract-version" => "1" },
                                            body: body.to_json, timeout: 15)
        data = JSON.parse(res.body.presence || "{}")
        return data if res.status == 200

        msg = data["XErr"].to_i == NO_PROFILE ? text(:no_profile) : "Xbox Live: #{data['XErr'] || data['Message'] || "HTTP #{res.status}"}"
        raise Integrations.auth(Integrations::Error.new(msg))
      rescue SafeHttp::Error, JSON::ParserError => e
        raise Integrations::Error, "Xbox Live: #{e.message}"
      end

      # Chamada ao SmartGlass na nuvem; 401 renova o XSTS (e o token da Microsoft) uma vez.
      def xbl(integration, method, path, body = nil, retry_auth: true)
        token, uhs = xsts(integration, force: !retry_auth)
        res = SafeHttp.request(method, "#{API}#{path}", headers: { "Authorization" => "XBL3.0 x=#{uhs};#{token}", "x-xbl-contract-version" => "4",
                                                                   "skillplatform" => "RemoteManagement", "Accept" => "application/json",
                                                                   "Content-Type" => "application/json" }, body: body&.to_json, timeout: 20)
        return xbl(integration, method, path, body, retry_auth: false) if res.status == 401 && retry_auth
        raise Integrations::Error, "Xbox: HTTP #{res.status}" unless res.status.between?(200, 299)

        JSON.parse(res.body.presence || "{}")
      rescue SafeHttp::Error, JSON::ParserError => e
        raise Integrations::Error, "Xbox: #{e.message}"
      end

      def entries(integration)
        Array(xbl(integration, "GET", "/lists/devices?queryCurrentDevice=false&includeStorageDevices=true")["result"]).map do |c|
          entry(id: "xbox:#{c['id']}", name: c["name"].presence || title, manufacturer: "Microsoft", model: c["consoleType"], category: "Mídia",
                address: { "id" => c["id"] }, poll_s: 60,
                points: [ point("media", "media", history: "none", address: { "supports" => SUPPORTS }),
                          point("remote", "remote", history: "none", address: { "codes" => BUTTONS.index_with(&:itself), "supports" => %w[send] }) ])
        end
      end

      def read(device)
        c = xbl(device.integration, "GET", "/consoles/#{CGI.escape(device.address['id'].to_s)}")
        on = c["powerState"] == "On"
        { "media" => { "state" => on ? "on" : "off", "app" => (c["focusAppAumid"].presence if on), "playback" => (c["playbackState"].presence if on) }.compact }
      end

      def command(point, command, value)
        type, name = COMMANDS.fetch(command) { command == "mute" ? [ "Audio", value == false ? "Unmute" : "Mute" ] : raise(Integrations::Error, "Xbox: #{command}?") }
        params = case command
        when "volume_up", "volume_down" then [ { "direction" => command == "volume_up" ? "Up" : "Down", "amount" => 1 } ]
        when "play_media" then [ { "oneStoreProductId" => value.to_s } ]
        when "send" then [ { "keyType" => value.to_s } ]
        else [ {} ]
        end
        xbl(point.device.integration, "POST", "/commands", { destination: "Xbox", type: type, command: name, sessionId: SecureRandom.uuid,
                                                            sourceId: "com.microsoft.smartglass", parameters: params, linkedXboxId: point.device.address["id"] })
      end
    end
  end
end
