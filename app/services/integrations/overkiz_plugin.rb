module Integrations
  # Overkiz (catalogo): Somfy TaHoma/Connexoon, Atlantic Cozytouch, Hitachi
  # Hi Kumo, Rexel e outros da plataforma Overkiz. Local (modo desenvolvedor
  # do TaHoma: `https://<gateway>:8443`, token Bearer) ou nuvem do servidor
  # (usuário e senha). Persianas e toldos (posição, abrir, fechar, parar),
  # luzes e tomadas (liga/desliga), e os sensores do estado.
  class OverkizPlugin < SchemaPlugin
    describe key: "overkiz", title: "Somfy TaHoma (Overkiz)", icon: "home",
             description: "Persianas, toldos, portões, luzes e sensores Somfy TaHoma, Connexoon e Cozytouch: posição, abrir, fechar, parar e liga/desliga, pela rede de casa ou pela nuvem."
    SERVERS = { "local" => nil, "somfy_europe" => "ha101-1.overkiz.com", "somfy_america" => "ha401-1.overkiz.com",
                "somfy_oceania" => "ha201-1.overkiz.com", "hi_kumo" => "ha117-1.overkiz.com", "rexel" => "ha112-1.overkiz.com" }.freeze
    texts "pt-BR" => { fields: { server: "Onde", token: "Token do modo desenvolvedor (local)" }, hints: { host: "gateway-xxxx-xxxx-xxxx.local (local)" },
                       options: { server: { local: "Na rede de casa (modo desenvolvedor do TaHoma)", somfy_europe: "Nuvem Somfy (Europa)", somfy_america: "Nuvem Somfy (Américas)",
                                            somfy_oceania: "Nuvem Somfy (Oceania)", hi_kumo: "Hitachi Hi Kumo", rexel: "Rexel Energeasy" } },
                       points: { position: "Posição", open: "Abrir", close: "Fechar", stop: "Parar" },
                       note: "Local: ligue o modo desenvolvedor em somfy.com (TaHoma) e gere o token; nuvem: e-mail e senha da conta." },
          en: { title: "Somfy TaHoma (Overkiz)", description: "Somfy TaHoma, Connexoon and Cozytouch shades, awnings, gates, lights and sensors: position, open, close, stop and on/off, over your home network or the cloud.",
                fields: { server: "Where", token: "Developer mode token (local)" }, hints: { host: "gateway-xxxx-xxxx-xxxx.local (local)" },
                options: { server: { local: "On the home network (TaHoma developer mode)", somfy_europe: "Somfy cloud (Europe)", somfy_america: "Somfy cloud (Americas)",
                                     somfy_oceania: "Somfy cloud (Oceania)", hi_kumo: "Hitachi Hi Kumo", rexel: "Rexel Energeasy" } },
                points: { position: "Position", open: "Open", close: "Close", stop: "Stop" },
                note: "Local: turn on developer mode at somfy.com (TaHoma) and create the token; cloud: the account e-mail and password." },
          es: { title: "Somfy TaHoma (Overkiz)", description: "Persianas, toldos, portones, luces y sensores Somfy TaHoma, Connexoon y Cozytouch: posición, abrir, cerrar, parar y encendido, por la red de casa o la nube.",
                fields: { server: "Dónde", token: "Token del modo desarrollador (local)" }, hints: { host: "gateway-xxxx-xxxx-xxxx.local (local)" },
                options: { server: { local: "En la red de casa (modo desarrollador de TaHoma)", somfy_europe: "Nube Somfy (Europa)", somfy_america: "Nube Somfy (Américas)",
                                     somfy_oceania: "Nube Somfy (Oceanía)", hi_kumo: "Hitachi Hi Kumo", rexel: "Rexel Energeasy" } },
                points: { position: "Posición", open: "Abrir", close: "Cerrar", stop: "Parar" },
                note: "Local: activa el modo desarrollador en somfy.com (TaHoma) y genera el token; nube: el e-mail y la contraseña de la cuenta." }
    field :server, :select, options: SERVERS.keys, default: "local"
    field :host
    field :token, secret: true
    field :username
    field :password, secret: true
    mdns "_kizboxdev._tcp"

    COVER = %w[RollerShutter ExteriorScreen Awning Screen Window Blind ExteriorVenetianBlind Pergola Curtain GarageDoor Gate].freeze

    class << self
      def local?(integration) = conf(integration, :server) == "local"

      def base(integration)
        local?(integration) ? "https://#{conf(integration, :host)}:8443/enduser-mobile-web/1/enduserAPI" : "https://#{SERVERS.fetch(conf(integration, :server))}/enduser-mobile-web/enduserAPI"
      end

      # Nuvem: login por formulário → cookie da sessão; local: Bearer.
      def call(integration, method, path, body = nil)
        url = "#{base(integration)}/#{path}"
        if local?(integration)
          return LanHttp.call(method, url, body: body, headers: { "Authorization" => "Bearer #{conf(integration, :token)}" }, insecure: true)
        end

        cookie = nil
        LanHttp.call(:post, "#{base(integration)}/login", body: URI.encode_www_form(userId: conf(integration, :username), userPassword: conf(integration, :password)),
                                                         headers: { "Content-Type" => "application/x-www-form-urlencoded" }) { |r| cookie = r["set-cookie"].to_s[/JSESSIONID=[^;]+/] }
        LanHttp.call(method, url, body: body, headers: { "Cookie" => cookie.to_s })
      end

      def states(d) = Array(d["states"]).to_h { |s| [ s["name"], s["value"] ] }
      def commands(d) = Array(d.dig("definition", "commands")).map { |c| c["commandName"] }

      def entries(integration)
        Array(call(integration, :get, "setup/devices")).filter_map do |d|
          cmds = commands(d)
          st = states(d)
          ui = d.dig("definition", "uiClass").to_s
          pts = []
          if COVER.include?(ui)
            pts << point("position", "dimmer", min: 0, max: 100) if cmds.include?("setClosure") || cmds.include?("setPosition")
            %w[open close stop].each { |c| pts << point(c, "command") if cmds.include?(c) }
          end
          pts << point("switch", "onoff", icon: ui == "Light" ? "light-bulb" : "power") if cmds.include?("on") && cmds.include?("off")
          pts << point("temperature", unit: "°C", device_class: "temperature", state_class: "measurement") if st.key?("core:TemperatureState")
          pts << point("battery", unit: "%", device_class: "battery") if st["core:BatteryLevelState"]
          next if pts.empty?

          entry(id: "overkiz:#{d['deviceURL']}", name: d["label"], manufacturer: "Somfy", model: d["controllableName"], category: ui,
                address: { "url" => d["deviceURL"] }, poll_s: 120, points: pts)
        end
      end

      def read(device)
        d = Array(call(device.integration, :get, "setup/devices")).find { |x| x["deviceURL"] == device.address["url"] }.to_h
        st = states(d)
        closure = st["core:ClosureState"]
        { "position" => (100 - closure.to_i if closure), "switch" => (st["core:OnOffState"] == "on" if st.key?("core:OnOffState")),
          "temperature" => st["core:TemperatureState"], "battery" => st["core:BatteryLevelState"] }
      end

      # Posição do MA: 100 = aberto; a Overkiz fecha (closure 100 = fechado).
      def command(point, command, value)
        f = point.address["field"]
        name, params = case f
        when "position" then [ "setClosure", [ 100 - value.to_i ] ]
        when "switch" then [ value ? "on" : "off", [] ]
        else [ f, [] ]
        end
        call(point.device.integration, :post, "exec/apply", { label: "Minha Automação", actions: [ { deviceURL: point.device.address["url"], commands: [ { name: name, parameters: params } ] } ] })
      end
    end
  end
end
