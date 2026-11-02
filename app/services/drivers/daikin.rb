module Drivers
  # Daikin (integ2): adaptador Wi-Fi BRP069/BRP072 pela API HTTP local
  # (`/common/basic_info`, `/aircon/get_control_info`, `get_sensor_info`,
  # `set_control_info`), respostas "chave=valor,…". O set precisa de todos os
  # campos de controle: lê o atual e troca um. Endereço {host, port}.
  class Daikin < Climate
    def self.vendor = "daikin"
    def self.base(address) = "http://#{address['host']}:#{(address['port'].presence || 80).to_i}"
    def self.get(address, path) = parse(LanHttp.get("#{base(address)}#{path}", raw: true))

    # "ret=OK,pow=1,name=%53%61%6c%61" → {"ret"=>"OK", "pow"=>"1", "name"=>"Sala"}
    def self.parse(text)
      h = text.to_s.split(",").to_h { |kv| k, v = kv.split("=", 2); [ k, URI.decode_www_form_component(v.to_s) ] }
      raise Integrations::Error, "O Daikin respondeu #{h['ret'] || 'vazio'}." unless h["ret"] == "OK"

      h
    end

    def self.entry(integration)
      address = { "host" => integration.settings["host"], "port" => (integration.settings["port"].presence || 80).to_i }
      info = get(address, "/common/basic_info")
      climate_entry(id: "daikin:#{info['mac'].presence || address['host']}", name: info["name"].presence || "Daikin",
                    manufacturer: "Daikin", model: info["ver"], address: address)
    end

    def self.number(v) = v.to_s.match?(/\A-?\d+(\.\d+)?\z/) ? v.to_f : nil

    def self.read(device)
      c = get(device.address, "/aircon/get_control_info")
      s = get(device.address, "/aircon/get_sensor_info")
      { "power" => c["pow"] == "1", "mode" => label("mode", c["mode"]), "target" => number(c["stemp"]), "fan" => label("fan", c["f_rate"]),
        "current" => number(s["htemp"]) }
    end

    def self.write(device, field, value)
      c = get(device.address, "/aircon/get_control_info")
      q = c.slice("pow", "mode", "stemp", "shum", "f_rate", "f_dir")
      case field
      when "power" then q["pow"] = value ? "1" : "0"
      when "target" then q["stemp"] = value.to_f.to_s
      when "fan" then q["f_rate"] = code("fan", value)
      when "mode"
        q["mode"] = code("mode", value)
        q["stemp"] = c["dt#{q['mode']}"].presence || q["stemp"] # o Daikin guarda a temperatura de cada modo
        q["shum"] = c["dh#{q['mode']}"].presence || q["shum"]
      end
      get(device.address, "/aircon/set_control_info?#{URI.encode_www_form(q)}")
    end
  end
end
