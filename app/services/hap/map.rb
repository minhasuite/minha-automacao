module Hap
  # Banco de acessórios do HAP (/accessories) → aparelhos e pontos, pelo mapa
  # `config/device_maps/homekit.yml` (característica → ponto). Nada aqui
  # conhece marca. Característica nova = uma linha no mapa.
  module Map
    INFO = "3E" # Accessory Information
    module_function

    def data = @data ||= YAML.load_file(Rails.root.join("config/device_maps/homekit.yml"))

    def info(acc)
      chars = Array(acc["services"]).find { |s| Hap.short_type(s["type"]) == INFO }&.dig("characteristics").to_a
      chars.to_h { |c| [ Hap.short_type(c["type"]), c["value"] ] }
    end

    # Acessório (aid) → entrada do inventário (formato de `Integrations`).
    def entry(accessory_id, acc)
      i = info(acc)
      { "id" => "homekit:#{accessory_id}:#{acc['aid']}", "kind" => "homekit", "name" => i["23"].presence || "HomeKit #{acc['aid']}",
        "manufacturer" => i["20"], "model" => i["21"], "category" => "HomeKit", "online" => true, "poll_s" => 60,
        "address" => { "aid" => acc["aid"] }, "points" => points(acc) }
    end

    def points(acc)
      list = Array(acc["services"]).reject { |s| Hap.short_type(s["type"]) == INFO }.flat_map do |s|
        Array(s["characteristics"]).filter_map do |c|
          spec = data["characteristics"][Hap.short_type(c["type"])] or next
          next unless Array(c["perms"]).include?("pr")

          [ spec, c, Array(c["perms"]).include?("pw") ]
        end
      end
      counts = list.map { |spec, _, _| spec["name"] }.tally
      list.map do |spec, c, writable|
        name = counts[spec["name"]] > 1 ? "#{spec['name']} #{c['iid']}" : spec["name"]
        spec.slice("capability", "unit", "device_class", "state_class", "options", "risk").merge(
          "name" => name, "writable" => writable && spec["capability"] != "contact", "min" => spec["min"] || c["minValue"], "max" => spec["max"] || c["maxValue"],
          "address" => { "aid" => acc["aid"], "iid" => c["iid"], "type" => Hap.short_type(c["type"]), "on" => spec["on"], "values" => spec["values"] }.compact
        ).compact
      end
    end

    # Bruto do HAP → valor do ponto (e de volta).
    def value(point, raw)
      a = point.address
      return if raw.nil?
      return Array(a["on"]).include?(raw.to_i) if a["on"]
      return a["values"][raw.to_s] || a["values"][raw.to_i] if a["values"]
      return raw == true || raw == 1 if point.bool?

      point.from_raw(raw)
    end

    def raw(point, value)
      a = point.address
      return a["values"].to_h.to_h { |k, v| [ v.to_s, k.to_i ] }.fetch(value.to_s) if a["values"]
      return value ? 1 : 0 if point.bool? && a["type"] == "B0"
      return value if point.bool?

      point.data_type == "integer" ? value.to_i : value.to_f
    end
  end
end
