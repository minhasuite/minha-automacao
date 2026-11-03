module Integrations
  # resto2 (grupo 9 #34; o `roborock` do HA): robôs Roborock da conta pela
  # nuvem da Roborock (Roborock): e-mail → a Roborock manda um código →
  # código no segundo Continuar; fica só o `rriot` da sessão (cifrado).
  # Robôs e cômodos pela API da casa (o mapa de segmentos pelo `get_room_mapping`),
  # estado e comandos pelo MQTT da Roborock. O robô vira o ponto `vacuum` (o
  # widget do robô com limpar cômodos), bateria, potência, área, duração e erro.
  # O desenho do mapa não entra (ver docs/catalogo.md).
  class RoborockPlugin < SchemaPlugin
    describe key: "roborock", title: "Roborock", icon: "sparkles",
             description: "Robôs aspiradores Roborock da sua conta pela nuvem: estado, bateria, limpar tudo ou só os cômodos, pausar, voltar à base e achar o robô."
    texts "pt-BR" => { fields: { username: "E-mail da conta Roborock", code: "Código do e-mail" }, hints: { code: "a Roborock manda por e-mail depois do primeiro Continuar" },
                       points: { vacuum: "Robô", fan: "Potência", area: "Área da limpeza", duration: "Duração da limpeza", error: "Erro" },
                       options: { fan: { "101" => "Silenciosa", "102" => "Equilibrada", "103" => "Turbo", "104" => "Máxima", "105" => "Desligada (só pano)" } },
                       need_code: "A Roborock mandou um código para o seu e-mail: digite em \"Código do e-mail\" e continue.",
                       failed: "A Roborock recusou: %{error}" },
          en: { title: "Roborock", description: "Roborock robot vacuums on your account through the cloud: status, battery, clean everything or just some rooms, pause, return to dock and locate.",
                fields: { username: "Roborock account e-mail", code: "E-mail code" }, hints: { code: "Roborock e-mails it after the first Continue" },
                points: { vacuum: "Robot", fan: "Suction", area: "Cleaned area", duration: "Cleaning time", error: "Error" },
                options: { fan: { "101" => "Quiet", "102" => "Balanced", "103" => "Turbo", "104" => "Max", "105" => "Off (mop only)" } },
                need_code: "Roborock sent a code to your e-mail: type it in \"E-mail code\" and continue.", failed: "Roborock refused: %{error}" },
          es: { title: "Roborock", description: "Robots aspiradores Roborock de tu cuenta por la nube: estado, batería, limpiar todo o solo algunas habitaciones, pausar, volver a la base y localizar.",
                fields: { username: "E-mail de la cuenta Roborock", code: "Código del e-mail" }, hints: { code: "Roborock lo envía por e-mail tras el primer Continuar" },
                points: { vacuum: "Robot", fan: "Potencia", area: "Área limpiada", duration: "Duración de la limpieza", error: "Error" },
                options: { fan: { "101" => "Silenciosa", "102" => "Equilibrada", "103" => "Turbo", "104" => "Máxima", "105" => "Apagada (solo mopa)" } },
                need_code: "Roborock envió un código a tu e-mail: escríbelo en \"Código del e-mail\" y continúa.", failed: "Roborock rechazó: %{error}" }
    field :username, required: true
    field :code

    # Código de estado da Roborock → estado do ponto vacuum.
    STATES = { 1 => "cleaning", 2 => "idle", 3 => "idle", 4 => "cleaning", 5 => "cleaning", 6 => "returning", 7 => "cleaning", 8 => "docked",
               9 => "error", 10 => "paused", 11 => "cleaning", 12 => "error", 13 => "idle", 14 => "idle", 15 => "returning", 16 => "cleaning",
               17 => "cleaning", 18 => "cleaning", 22 => "docked", 23 => "docked", 26 => "returning", 100 => "docked" }.freeze
    ACTIONS = { "start" => "app_start", "pause" => "app_pause", "stop" => "app_stop", "home" => "app_charge", "locate" => "find_me", "clean_rooms" => "app_segment_clean" }.freeze
    FAN = %w[101 102 103 104 105].freeze

    class << self
      def add_found(*) = nil

      def login(integration, form)
        email = form[:username].to_s.strip.presence || integration.settings["account"]
        device_id = integration.settings["device_id"].presence || SecureRandom.hex(8)
        integration.settings = integration.settings.merge("account" => email, "device_id" => device_id)
        code = form[:code].to_s.strip
        if code.blank?
          base = Roborock.account(Roborock::REGIONS.second, "/api/v1/getUrlByEmail?#{{ email: email }.to_query}", email: email, device_id: device_id).to_h["url"].presence ||
                 Roborock::REGIONS.second
          Roborock.account(base, "/api/v1/sendEmailCode?#{{ username: email, type: 'auth' }.to_query}", email: email, device_id: device_id)
          integration.settings = integration.settings.merge("base" => base)
          integration.save!
          return outcome(:connect, integration: integration, alert: text(:need_code))
        end
        data = Roborock.account(integration.settings["base"].presence || Roborock::REGIONS.second,
                                "/api/v1/loginWithCode?#{{ username: email, verifycode: code, verifycodetype: 'AUTH_EMAIL_CODE' }.to_query}", email: email, device_id: device_id).to_h
        integration.credentials = { "token" => data["token"], "rriot" => data["rriot"] }.to_json
        integration.save!
        r = Integrations.sync!(integration)
        outcome(:found, integration: integration, notice: text(:read, n: r[:found]))
      rescue Roborock::Error, Integrations::Error => e
        integration.save! if integration.new_record? && integration.settings["base"].present?
        outcome(integration.persisted? ? :connect : :form, integration: integration.persisted? ? integration : nil, alert: text(:failed, error: e.message))
      end

      def rriot(integration) = integration.secrets["rriot"].presence || raise(Integrations.auth(Integrations::Error.new(text(:failed, error: "login"))))

      def call(integration)
        yield
      rescue Roborock::Error => e
        raise Integrations::Error, e.message
      end

      def entries(integration)
        call(integration) do
          s = integration.settings
          home_id = Roborock.account(s["base"], "/api/v1/getHomeDetail", email: s["account"], device_id: s["device_id"], token: integration.secrets["token"], method: "GET").to_h["rrHomeId"]
          home = Roborock.home(rriot(integration), home_id)
          products = Array(home["products"]).index_by { |p| p["id"] }
          names = Array(home["rooms"]).to_h { |r| [ r["id"].to_s, r["name"] ] }
          (Array(home["devices"]) + Array(home["receivedDevices"])).map do |d|
            rooms = begin
              Array(Roborock.rpc(rriot(integration), d["duid"], d["localKey"], "get_room_mapping")).filter_map { |seg, room| { "id" => seg.to_i, "name" => names[room.to_s] || "Cômodo #{seg}" } if seg }
            rescue Roborock::Error
              [] # robô desligado agora: os cômodos vêm na próxima varredura
            end
            product = products[d["productId"]].to_h
            entry(id: "roborock:#{d['duid']}", name: d["name"].presence || product["name"] || title, manufacturer: "Roborock", model: product["model"],
                  category: "Limpeza", address: { "duid" => d["duid"] }, secret: d["localKey"], poll_s: 60,
                  points: [ point("vacuum", "vacuum", history: "on_change", address: { "role" => "vacuum", "actions" => ACTIONS, "rooms" => rooms }),
                            point("battery", unit: "%", device_class: "battery", address: { "role" => "battery" }),
                            point("fan", "enum", options: FAN.map { |f| option_label(:fan, f) }, history: "on_change", address: { "role" => "suction" }),
                            point("area", unit: "m²"), point("duration", unit: "min"), point("error", "problem") ])
          end
        end
      end

      def rpc(device, method, params = []) = call(device.integration) { Roborock.rpc(rriot(device.integration), device.address["duid"], device.credential, method, params) }

      def read(device)
        st = Array(rpc(device, "get_status")).first.to_h
        { "vacuum" => STATES[st["state"].to_i], "battery" => st["battery"], "fan" => (option_label(:fan, st["fan_power"].to_s) if FAN.include?(st["fan_power"].to_s)),
          "area" => (st["clean_area"].to_f / 1_000_000).round(1), "duration" => (st["clean_time"].to_i / 60.0).round, "error" => st["error_code"].to_i.positive? }
      end

      def write(point, value)
        code = FAN.find { |f| option_label(:fan, f) == value.to_s } or raise Integrations::Error, "Roborock: potência #{value}?"
        rpc(point.device, "set_custom_mode", [ code.to_i ])
      end

      def command(point, command, value)
        return write(point, value) unless point.capability == "vacuum"

        params = command == "clean_rooms" ? [ { "segments" => Array(value["rooms"]).map(&:to_i), "repeat" => 1 } ] : []
        rpc(point.device, ACTIONS.fetch(command) { raise Integrations::Error, "Roborock: #{command}?" }, params)
      end
    end
  end
end
