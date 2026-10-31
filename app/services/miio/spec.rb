require "net/http"

module Miio
  # Pontos de um aparelho Xiaomi pelo modelo: robô aspirador usa o mapa de
  # `Miio::Vacuum`; o resto lê a especificação pública MIoT (miot-spec.org,
  # sem login) e vira ponto o que tem tradução direta (liga/desliga, brilho,
  # temperatura, umidade, bateria, potência). Sem rede ou modelo desconhecido
  # = sem pontos (o aparelho entra e os pontos podem ser criados à mão).
  module Spec
    HOST = "https://miot-spec.org".freeze
    # Propriedade → ponto: dado em config/device_maps/miot.yml.
    PROPS = YAML.load_file(Rails.root.join("config/device_maps/miot.yml"))["properties"].freeze

    module_function

    def vacuum?(model) = model.to_s.include?(".vacuum.")

    def points(model)
      return Vacuum.points([]).map { |p| p.deep_stringify_keys } if vacuum?(model)

      urn = instances[model.to_s] or return []
      services = Array(fetch("/miot-spec-v2/instance?type=#{URI.encode_www_form_component(urn)}")["services"])
      list = services.flat_map do |s|
        Array(s["properties"]).filter_map do |p|
          kind = p["type"].to_s.split(":")[3]
          spec = PROPS[kind] or next
          next if spec["writable_only"] && !Array(p["access"]).include?("write")

          name = [ spec["name"], (s["description"] if services.count { |o| Array(o["properties"]).any? { |q| q["type"].to_s.split(":")[3] == kind } } > 1) ].compact.join(" ")
          attrs = spec.except("writable_only", "color").merge("name" => name, "address" => { "siid" => s["iid"], "piid" => p["iid"] })
          attrs["address"]["color"] = color_siblings(spec["color"], s) if spec["color"]
          range = p["value-range"]
          attrs.merge!("scale" => (100.0 / range[1]).round(6), "min" => 1, "max" => 100) if attrs["capability"] == "dimmer" && range
          attrs
        end
      end
      list.uniq { |p| p["address"].values_at("siid", "piid") }
    rescue StandardError => e
      Rails.logger.warn("[miot-spec] #{model}: #{e.message}")
      []
    end

    # Cor (Lote 8): a propriedade irmã (pelo nome do tipo) no mesmo serviço vira siid/piid; sem ela, sai.
    def color_siblings(conf, service)
      conf.filter_map do |k, h|
        next [ k, h ] unless h.is_a?(Hash) && h["property"]

        p = Array(service["properties"]).find { |q| q["type"].to_s.split(":")[3] == h["property"] } or next
        [ k, h.except("property").merge("siid" => service["iid"], "piid" => p["iid"]) ]
      end.to_h
    end

    # modelo → urn da versão mais nova (lista pública, guardada um dia).
    def instances
      Rails.cache.fetch("miot-spec/instances", expires_in: 1.day) do
        Array(fetch("/miot-spec-v2/instances?status=all")["instances"]).sort_by { |i| i["version"].to_i }.to_h { |i| [ i["model"], i["type"] ] }
      end
    end

    def fetch(path)
      uri = URI(HOST + path)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |h| h.get(uri.request_uri) }
      raise "miot-spec respondeu #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    end
  end
end
