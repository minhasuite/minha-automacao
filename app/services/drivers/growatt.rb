module Drivers
  # Growatt (integ2): usinas da conta pela OpenAPI v1 (token da conta, em
  # ShineServer → Configurações → API). Cada usina vira um aparelho com
  # potência de agora e energia do dia e total, para os painéis de energia.
  # Só leitura, a cada 5 min (a nuvem atualiza a cada 5). Endereço {plant_id}.
  class Growatt
    URL = "https://openapi.growatt.com/v1".freeze
    AUTH_CODES = [ 10_011, 10_012 ].freeze # token inválido / sem permissão
    POINTS = [
      { "name" => "Potência", "capability" => "measure", "unit" => "W", "device_class" => "power", "state_class" => "measurement", "address" => { "field" => "current_power" } },
      { "name" => "Energia hoje", "capability" => "measure", "unit" => "kWh", "device_class" => "energy", "state_class" => "total_increasing", "address" => { "field" => "today_energy" } },
      { "name" => "Energia total", "capability" => "measure", "unit" => "kWh", "device_class" => "energy", "state_class" => "total_increasing", "address" => { "field" => "total_energy" } }
    ].freeze

    def self.api(integration, path)
      r = LanHttp.get("#{URL}/#{path}", headers: { "token" => integration.secrets["token"].to_s }, timeout: 15)
      code = r["error_code"].to_i
      return r["data"].to_h if code.zero?

      e = Integrations::Error.new("A Growatt recusou: #{r['error_msg'].presence || code}")
      raise AUTH_CODES.include?(code) ? Integrations.auth(e) : e
    end

    def self.inventory(integration)
      Array(api(integration, "plant/list")["plants"]).map do |p|
        { "id" => "growatt:#{p['plant_id']}", "kind" => "growatt", "name" => p["name"].presence || "Usina solar", "manufacturer" => "Growatt",
          "model" => ("#{p['peak_power']} kWp" if p["peak_power"]), "category" => "Inversor solar", "room" => p["city"], "online" => true,
          "poll_s" => 300, "address" => { "plant_id" => p["plant_id"].to_s }, "points" => POINTS }
      end
    end

    def self.poll(device)
      data = api(device.integration, "plant/data?plant_id=#{CGI.escape(device.address['plant_id'].to_s)}")
      device.update_columns(status: "online", last_seen_at: Time.current)
      device.points.reject(&:disabled).each do |p|
        v = data[p.address["field"]]
        p.report!(v.to_f.round(3)) if v.to_s.match?(/\A-?\d+(\.\d+)?\z/)
      end
    end

    def self.unavailable!(device) = Drivers.offline!(device)

    def execute(_point, _command, _value) = raise(Integrations::Error, "A usina só é lida, não recebe comando.")
  end
end
