module HelperTypes
  # Derivada (derivative do HA): taxa de variação da origem por unidade de
  # tempo (°C/h, kWh/h = kW). Sem janela: entre as duas últimas leituras;
  # com janela: do primeiro ao último valor dentro dela (a média ponderada das
  # taxas, como o `time_window` do HA). Prefixo de unidade e casas decimais.
  # Origem fora do ar = as amostras recomeçam na volta.
  class Derivative < Plugin
    MAX_SAMPLES = 200

    describe key: "derivative", title: "Derivada", icon: "trending-up", capability: "measure",
             description: "Quanto um valor muda por tempo: temperatura subindo 2 °C/h, energia em kWh/h."
    fields %i[source window prefix time_unit round]

    def self.assign(point, form)
      src = numeric_source!(point, form) or return
      a = point.address
      prefix = (form.key?("prefix") ? form["prefix"].to_s : a["prefix"].to_s).presence_in(PREFIXES.keys) || ""
      unit = (form["time_unit"] || a["time_unit"]).presence_in(TIME_UNITS.keys) || "h"
      round = (number(form["round"]) || a["round"] || 3).to_i
      window = form.key?("window") ? Automations::Dsl.seconds(form["window"].to_s.strip.presence || 0) : a["window_s"].to_i
      point.data_type = "decimal"
      point.writable = false
      point.unit = "#{prefix}#{src.unit}/#{unit}"
      point.address = a.merge("prefix" => prefix, "time_unit" => unit, "round" => round, "window_s" => window.to_i)
      point.errors.add(:base, "Casas decimais de 0 a 6.") unless round.between?(0, 6)
      point.errors.add(:base, "Janela inválida (vazio = sem janela; ex.: 10m, 1h, até 1 dia).") unless window&.between?(0, 86_400)
    end

    def self.sourced? = true

    def self.refresh!(point, now = Time.current)
      window = point.address["window_s"].to_i
      samples = samples!(point, now, window: window, max: window.positive? ? MAX_SAMPLES : 2)
      (t0, v0), (t1, v1) = samples.first, samples.last
      return point.report!(nil) if samples.size < 2 || t1 <= t0

      a = point.address
      rate = (v1 - v0) / (t1 - t0) * TIME_UNITS[a["time_unit"]] / PREFIXES[a["prefix"].to_s]
      point.report!(rate.round(a["round"].to_i))
    end

    # Amostras [[segundos, valor]] da origem em `address.state.samples`: põe a
    # leitura de agora, tira as mais velhas que a janela `window` (0 = sem
    # janela) e fica com as `max` últimas. Origem fora do ar = esvazia.
    # Serve à derivada e à tendência.
    def self.samples!(point, now, window:, max:)
      v = reading(source(point))
      list = v.nil? ? [] : Array(state(point)["samples"]) + [ [ now.to_f, v ] ]
      recent = window.positive? ? list.select { |t, _| t >= now.to_f - window } : list
      # Leituras mais espaçadas que a janela: fica com as duas últimas.
      list = (recent.size >= 2 ? recent : list.last(2)).last(max)
      save_state!(point, { "samples" => list })
      list
    end

    def self.summary(point)
      w = point.address["window_s"].to_i
      [ "em #{point.unit}", (w.positive? ? "janela de #{Automations::Dsl.duration_label(w)}" : "entre as duas últimas leituras") ].join(" · ")
    end
  end
end
