module Integrations
  # Fully Kiosk Browser (catalogo): tablet de parede com o app Fully, pela API
  # REST do próprio app (porta 2323, senha do "Remote Administration"). Tela,
  # brilho, bateria, página aberta e os botões de recarregar e de trazer o app
  # para a frente.
  class FullyKioskPlugin < SchemaPlugin
    describe key: "fully_kiosk", title: "Fully Kiosk Browser", icon: "device-mobile",
             description: "Tablets de parede com o Fully Kiosk Browser: liga e desliga a tela, brilho, bateria, a página aberta e os botões de recarregar e abrir a página inicial."
    texts "pt-BR" => { points: { screen: "Tela", page: "Página aberta", reload: "Recarregar", start_url: "Abrir página inicial", foreground: "Trazer para a frente" },
                       note: "No Fully: Configurações → Remote Administration (ligar) e a senha dele aqui." },
          en: { title: "Fully Kiosk Browser", description: "Wall tablets running Fully Kiosk Browser: screen on and off, brightness, battery, the open page and buttons to reload and open the start page.",
                points: { screen: "Screen", page: "Open page", reload: "Reload", start_url: "Open start page", foreground: "Bring to front" },
                note: "In Fully: Settings → Remote Administration (turn on) and its password here." },
          es: { title: "Fully Kiosk Browser", description: "Tablets de pared con Fully Kiosk Browser: enciende y apaga la pantalla, brillo, batería, la página abierta y los botones para recargar y abrir la página inicial.",
                points: { screen: "Pantalla", page: "Página abierta", reload: "Recargar", start_url: "Abrir página inicial", foreground: "Traer al frente" },
                note: "En Fully: Configuración → Remote Administration (activar) y su contraseña aquí." }
    field :host, required: true
    field :port, :number, default: 2323
    field :password, secret: true, required: true

    BUTTONS = { "reload" => "loadStartURL", "foreground" => "toForeground" }.freeze

    class << self
      def api(integration, query)
        base = LanHttp.base("#{conf(integration, :host)}:#{conf(integration, :port)}")
        r = LanHttp.get("#{base}/?#{query.merge(type: 'json', password: conf(integration, :password)).to_query}")
        raise Integrations.auth(Integrations::Error.new(r["statustext"].to_s)) if r["status"] == "Error"

        r
      end

      def entries(integration)
        info = api(integration, cmd: "deviceInfo")
        [ entry(id: "fully:#{info['deviceID'].presence || conf(integration, :host)}", name: info["deviceName"].presence || "#{info['deviceManufacturer']} #{info['deviceModel']}".strip,
                manufacturer: info["deviceManufacturer"], model: info["deviceModel"], category: "Fully #{info['appVersionName']}".strip, poll_s: 60,
                points: [ point("screen", "onoff", icon: "device-mobile"), point("brightness", "dimmer", min: 0, max: 255),
                          point("battery", unit: "%", device_class: "battery", state_class: "measurement"), point("page", "text", writable: true),
                          point("reload", "command"), point("foreground", "command") ]) ]
      end

      def read(device)
        info = api(device.integration, cmd: "deviceInfo")
        { "screen" => info.key?("screenOn") ? info["screenOn"] : info["isScreenOn"], "brightness" => info["screenBrightness"],
          "battery" => info["batteryLevel"], "page" => info["currentPage"] }
      end

      def write(point, value)
        i = point.device.integration
        case (f = point.address["field"])
        when "screen" then api(i, cmd: value ? "screenOn" : "screenOff")
        when "brightness" then api(i, cmd: "setStringSetting", key: "screenBrightness", value: value.to_i)
        when "page" then api(i, cmd: "loadURL", url: value.to_s)
        else api(i, cmd: BUTTONS.fetch(f))
        end
      end
    end
  end
end
