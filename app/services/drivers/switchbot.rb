require "base64"

module Drivers
  # SwitchBot (integ): API de nuvem v1.1 com o token e o segredo da conta do
  # usuário (app SwitchBot → Perfil → Preferências → Opções de desenvolvedor).
  # Cada pedido é assinado (HMAC-SHA256 de token + t + nonce). Tipos de
  # aparelho → pontos pelo `config/device_maps/switchbot.yml`; leitura a cada
  # 5 min (a conta tem 10 mil pedidos por dia) e o comando grava o valor pedido.
  class Switchbot
    URL = "https://api.switch-bot.com/v1.1".freeze
    MAP = YAML.load_file(Rails.root.join("config/device_maps/switchbot.yml")).freeze
    ATTRS = %w[name capability unit device_class state_class min max step icon risk].freeze
    COMMANDS = {
      "power" => ->(_p, v) { [ v ? "turnOn" : "turnOff", "default" ] },
      "position" => ->(_p, v) { [ "setPosition", "0,ff,#{(100 - v.to_i).clamp(0, 100)}" ] },
      "brightness" => ->(_p, v) { [ "setBrightness", v.to_i.clamp(1, 100) ] },
      "color" => ->(_p, v) { [ "setColor", Points::Color.rgb(v.merge("v" => 100)).join(":") ] },
      "lock" => ->(p, _v) { [ p.value == "closed" ? "unlock" : "lock", "default" ] }
    }.freeze

    def self.headers(token, secret, t: (Time.now.to_f * 1000).to_i, nonce: SecureRandom.uuid)
      sign = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret.to_s, "#{token}#{t}#{nonce}"))
      { "Authorization" => token.to_s, "sign" => sign, "t" => t.to_s, "nonce" => nonce }
    end

    def self.api(integration, method, path, body = nil)
      s = integration.secrets
      r = LanHttp.call(method, "#{URL}#{path}", body: body, headers: headers(s["token"], s["secret"]), timeout: 15)
      return r["body"] || {} if r["statusCode"].to_i == 100

      raise Integrations::Error, "A SwitchBot recusou: #{r['message'].presence || r['statusCode']}"
    end

    def self.fields(type) = MAP["types"][MAP["alias"].fetch(type.to_s, type.to_s)]

    def self.inventory(integration)
      Array(api(integration, :get, "/devices")["deviceList"]).filter_map do |d|
        f = fields(d["deviceType"]) or next
        { "id" => "switchbot:#{d['deviceId']}", "kind" => "switchbot", "name" => d["deviceName"].presence || d["deviceType"], "manufacturer" => "SwitchBot",
          "model" => d["deviceType"], "category" => "SwitchBot", "online" => true, "poll_s" => 300, "address" => { "device_id" => d["deviceId"] },
          "points" => f.map { |x| { "capability" => "measure" }.merge(x.slice(*ATTRS)).merge("address" => x.slice("field", "cmd", "map", "invert")) } }
      end
    end

    def self.value(point, status)
      a = point.address
      raw = status[a["field"]]
      return if raw.nil?
      return Points::Color.from_rgb(raw.to_s.split(":").map(&:to_i)) if point.capability == "color"

      raw = a["map"].fetch(raw.to_s, raw) if a["map"]
      raw = 100 - raw.to_i if a["invert"] # SwitchBot: 0 = aberta; no MA, 100 = aberta
      point.from_raw(raw)
    end

    def self.poll(device)
      status = api(device.integration, :get, "/devices/#{device.address['device_id']}/status")
      device.update_columns(status: "online", last_seen_at: Time.current)
      device.points.reject(&:disabled).each { |p| (v = value(p, status)).nil? || p.report!(v) }
    end

    def self.unavailable!(device) = Drivers.offline!(device)

    def execute(point, command, value)
      v = Points::Command.new(point, command, value).new_value
      cmd, param = COMMANDS.fetch(point.address["cmd"]).call(point, v)
      self.class.api(point.device.integration, :post, "/devices/#{point.device.address['device_id']}/commands",
                     { command: cmd, parameter: param, commandType: "command" })
      point.report!(v) # nuvem demora a refletir: grava o pedido (portão: o Points::Command já inverteu)
    end
  end
end
