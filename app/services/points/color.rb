module Points
  # Cor de lâmpada (Lote 8): valor do ponto `color` e o comando `set`.
  # Aceita {"hs" => [h, s]}, {"h" =>, "s" =>}, {"rgb" => [r, g, b]},
  # "#rrggbb", {"kelvin" => k} ou {"mireds" => m}, com "v" (0 a 100)
  # opcional. Guarda {"mode" => "hs", "h", "s"[, "v"]} ou
  # {"mode" => "temp", "kelvin"}.
  #
  # Como a cor chega no aparelho vem do endereço do ponto (`address.color`,
  # montado pelo mapa de dados: config/device_maps/tuya.yml e miot.yml), sem
  # código por aparelho:
  #   hs:   {format: <FORMATS>, s_max:, v_max:} no dp/propriedade do próprio ponto;
  #   temp: {<endereço do irmão>, raw_min:, raw_max:, min_k:, max_k:}; kelvin →
  #         bruto linear (sem raw_max, o bruto é o próprio kelvin);
  #   mode: {<endereço do irmão>, hs: "colour", temp: "white"}: o modo da lâmpada, gravado junto.
  # Formato novo = uma linha em FORMATS ([codificar, decodificar]).
  module Color
    FORMATS = {
      "hsv_json" => [
        ->(c, f) { { "h" => c["h"].round, "s" => scale(c["s"], f["s_max"]), "v" => scale(c.fetch("v", 100), f["v_max"]) }.to_json },
        ->(raw, f) { (d = hsv_hash(raw)) ? hs(d["h"], unscale(d["s"], f["s_max"]), unscale(d["v"], f["v_max"])) : nil }
      ],
      # Tuya pela LAN: "hhhhssssvvvv" (hex de 4 dígitos cada).
      "hsv_hex" => [
        ->(c, f) { format("%04x%04x%04x", c["h"].round, scale(c["s"], f["s_max"]), scale(c.fetch("v", 100), f["v_max"])) },
        ->(raw, f) { FORMATS["hsv_json"].last.call(raw, f) }
      ],
      "rgb_int" => [
        ->(c, _f) { rgb(c.merge("v" => 100)).then { |r, g, b| (r << 16) | (g << 8) | b } }, # brilho é outra propriedade
        ->(raw, _f) { raw.is_a?(Integer) ? from_rgb([ (raw >> 16) & 255, (raw >> 8) & 255, raw & 255 ]) : nil }
      ]
    }.freeze
    CONFIG_KEYS = %w[format via s_max v_max raw_min raw_max min_k max_k hs temp].freeze
    KELVIN = (1000..12_000)

    module_function

    def error(msg) = Command::Error.new(:invalid_value, msg)

    # Valor do comando → valor guardado (levanta Command::Error).
    def normalize(point, value)
      v = value.is_a?(String) ? { "rgb" => hex(value) } : value.to_h.stringify_keys
      c = if v["kelvin"] || v["mireds"]
        k = v["kelvin"] ? num(v["kelvin"]) : 1_000_000 / num(v["mireds"]).then { |m| m.positive? ? m : raise(error("mireds precisa ser positivo.")) }
        { "mode" => "temp", "kelvin" => k.round.clamp(KELVIN) }
      elsif v["rgb"] then from_rgb(Array(v["rgb"]).map { |x| num(x).round.clamp(0, 255) }.tap { |l| raise error("rgb precisa de 3 números.") if l.size != 3 })
      elsif v["hs"] || v.key?("h") then hs(*(v["hs"] ? Array(v["hs"]) : v.values_at("h", "s")).map { |x| num(x) })
      else raise error("Informe a cor: hs, rgb, #rrggbb, kelvin ou mireds.")
      end
      c["v"] = num(v["v"]).clamp(0, 100).round if v.key?("v") && !v["v"].nil?
      conf = point.address["color"].to_h
      raise error("#{point.name} não aceita #{c['mode'] == 'temp' ? 'temperatura de cor' : 'cor'}.") if conf.any? && !conf.key?(c["mode"])

      c
    end

    # {h, s, v} brutos: JSON (nuvem) ou "hhhhssssvvvv" (LAN).
    def hsv_hash(raw)
      return raw if raw.is_a?(Hash)
      return %w[h s v].zip(raw.scan(/\h{4}/).map { |x| x.to_i(16) }).to_h if raw.is_a?(String) && raw.match?(/\A\h{12}\z/)

      (d = JSON.parse(raw.to_s)).is_a?(Hash) ? d : nil
    end

    # [[endereço, valor bruto]] a gravar no aparelho (modo antes da cor).
    # `via`: o caminho do comando (driver); `hs.via` no mapa troca o formato
    # por caminho (a Tuya fala JSON na nuvem e hex na LAN).
    def writes(point, value, via = nil)
      conf = point.address["color"].to_h
      mode = conf["mode"] && [ conf["mode"].except(*CONFIG_KEYS, "hs", "temp"), conf["mode"][value["mode"]] ]
      write = if value["mode"] == "temp"
        t = conf.fetch("temp")
        [ t.except(*CONFIG_KEYS), kelvin_raw(t, value["kelvin"]) ]
      else
        f = conf.fetch("hs")
        [ point.address.except("color"), FORMATS.fetch(f.dig("via", via.to_s) || f["format"]).first.call(value.merge("v" => value["v"] || brightness(point)), f) ]
      end
      [ (mode if mode&.last), write ].compact
    end

    # Bruto do aparelho (dp da cor) → valor guardado (nil = não sabe ler).
    def decode(address, raw)
      f = address.dig("color", "hs") or return nil
      FORMATS.fetch(f["format"]).last.call(raw, f)
    rescue JSON::ParserError, TypeError, KeyError
      nil
    end

    # Brilho do irmão `dimmer` do mesmo aparelho (o "v" da cor na Tuya); sem ele, 100.
    def brightness(point) = point.device&.points&.find { |p| p.capability == "dimmer" }&.value.then { |b| b.is_a?(Numeric) ? b.clamp(1, 100) : 100 }

    def kelvin_raw(t, kelvin)
      return kelvin.round unless t["raw_max"]

      lo, hi = t.fetch("min_k", 2000).to_f, t.fetch("max_k", 6500).to_f
      min = t.fetch("raw_min", 0).to_f
      (min + ((kelvin.clamp(lo, hi) - lo) / (hi - lo) * (t["raw_max"].to_f - min))).round
    end

    def num(x)
      Float(x.to_s.tr(",", "."))
    rescue ArgumentError, TypeError
      raise error("Cor inválida: #{x.inspect.truncate(30)} não é número.")
    end

    def hex(s)
      m = s.to_s.strip.match(/\A#?(\h{2})(\h{2})(\h{2})\z/) or raise error("Cor inválida (use #rrggbb).")
      m.captures.map { |x| x.to_i(16) }
    end

    # Valor guardado → "#rrggbb" do seletor de cor da tela (temperatura: branco).
    def hex_of(c) = c.is_a?(Hash) && c["mode"] == "hs" ? format("#%02x%02x%02x", *rgb(c.merge("v" => 100))) : "#ffffff"

    def hs(h, s, v = nil) = { "mode" => "hs", "h" => (h.to_f % 360).round(1), "s" => s.to_f.clamp(0, 100).round(1), "v" => v&.round }.compact
    def scale(x, max) = (x.to_f * (max || 1000).to_f / 100).round
    def unscale(x, max) = x.to_f * 100 / (max || 1000).to_f

    def from_rgb(list)
      r, g, b = list.map { |x| x.to_f / 255 }
      max, min = [ r, g, b ].max, [ r, g, b ].min
      d = max - min
      h = if d.zero? then 0
      elsif max == r then 60 * (((g - b) / d) % 6)
      elsif max == g then 60 * (((b - r) / d) + 2)
      else 60 * (((r - g) / d) + 4)
      end
      hs(h, max.zero? ? 0 : d / max * 100)
    end

    def rgb(c)
      h, s, v = c["h"].to_f, c["s"].to_f / 100, c.fetch("v", 100).to_f / 100
      f = ->(n) { k = (n + (h / 60)) % 6; v - (v * s * [ [ k, 4 - k, 1 ].min, 0 ].max) }
      [ f.call(5), f.call(3), f.call(1) ].map { |x| (x * 255).round }
    end
  end
end
