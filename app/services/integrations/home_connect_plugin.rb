module Integrations
  # Home Connect (catalogo): eletrodomésticos Bosch, Siemens, Neff, Gaggenau e
  # Thermador pela API Home Connect (OAuth do app do dono em
  # developer.home-connect.com). Estado da operação, porta, programa, tempo
  # que falta, progresso e liga/desliga.
  class HomeConnectPlugin < OauthPlugin
    describe key: "home_connect", title: "Home Connect (Bosch, Siemens)", icon: "cog",
             description: "Lava-louças, lavadoras, secadoras, fornos, geladeiras e cafeteiras Bosch, Siemens, Neff e Gaggenau: estado, porta, tempo que falta, progresso e liga/desliga."
    texts "pt-BR" => { points: { operation: "Operação", door: "Porta aberta", remaining: "Tempo que falta", progress: "Progresso", program: "Programa" },
                       note: "Crie o app em developer.home-connect.com → Applications (Authorization Code Grant Flow) e informe o Client ID e o secret dele." },
          en: { title: "Home Connect (Bosch, Siemens)", description: "Bosch, Siemens, Neff and Gaggenau dishwashers, washers, dryers, ovens, fridges and coffee machines: status, door, time left, progress and on/off.",
                points: { operation: "Operation", door: "Door open", remaining: "Time left", progress: "Progress", program: "Program" },
                note: "Create the app at developer.home-connect.com → Applications (Authorization Code Grant Flow) and enter its Client ID and secret." },
          es: { title: "Home Connect (Bosch, Siemens)", description: "Lavavajillas, lavadoras, secadoras, hornos, neveras y cafeteras Bosch, Siemens, Neff y Gaggenau: estado, puerta, tiempo restante, progreso y encendido.",
                points: { operation: "Operación", door: "Puerta abierta", remaining: "Tiempo restante", progress: "Progreso", program: "Programa" },
                note: "Crea la app en developer.home-connect.com → Applications (Authorization Code Grant Flow) e indica su Client ID y secret." }
    oauth authorize: "https://api.home-connect.com/security/oauth/authorize", token: "https://api.home-connect.com/security/oauth/token",
          scope: "IdentifyAppliance Monitor Settings Control"
    API = "https://api.home-connect.com/api/homeappliances".freeze
    POWER = "BSH.Common.Setting.PowerState".freeze

    class << self
      def api_headers = { "Accept" => "application/vnd.bsh.sdk.v1+json", "Content-Type" => "application/vnd.bsh.sdk.v1+json" }

      # "BSH.Common.EnumType.OperationState.Run" → "Run".
      def short(v) = v.to_s.split(".").last

      def entries(integration)
        Array(api(integration, :get, API).dig("data", "homeappliances")).map do |a|
          entry(id: "home_connect:#{a['haId']}", name: a["name"].presence || a["type"], manufacturer: a["brand"], model: a["vib"], category: a["type"],
                online: a["connected"], address: { "ha_id" => a["haId"] }, poll_s: 120,
                points: [ point("power", "onoff", name: text("points.switch"), icon: "power"), point("operation", "text", writable: false),
                          point("door", "contact"), point("program", "text", writable: false),
                          point("remaining", unit: "min", state_class: "measurement"), point("progress", unit: "%", state_class: "measurement") ])
        end
      end

      def read(device)
        i = device.integration
        base = "#{API}/#{device.address['ha_id']}"
        status = Array(api(i, :get, "#{base}/status").dig("data", "status")).to_h { |s| [ s["key"], s["value"] ] }
        power = begin
          api(i, :get, "#{base}/settings/#{POWER}").dig("data", "value")
        rescue Integrations::Error
          nil
        end
        active = begin
          api(i, :get, "#{base}/programs/active")["data"].to_h
        rescue Integrations::Error
          {} # sem programa rodando a API responde 404
        end
        opts = Array(active["options"]).to_h { |o| [ o["key"], o["value"] ] }
        { "power" => (short(power) == "On" if power), "operation" => short(status["BSH.Common.Status.OperationState"]).presence,
          "door" => (short(status["BSH.Common.Status.DoorState"]) == "Open" if status.key?("BSH.Common.Status.DoorState")),
          "program" => short(active["key"]).presence || "", "remaining" => ((opts["BSH.Common.Option.RemainingProgramTime"].to_i / 60.0).round if opts.any?) || 0,
          "progress" => opts["BSH.Common.Option.ProgramProgress"] || 0 }
      end

      def write(point, value)
        state = value ? "BSH.Common.EnumType.PowerState.On" : "BSH.Common.EnumType.PowerState.Off"
        api(point.device.integration, :put, "#{API}/#{point.device.address['ha_id']}/settings/#{POWER}", { data: { key: POWER, value: state } })
      end
    end
  end
end
