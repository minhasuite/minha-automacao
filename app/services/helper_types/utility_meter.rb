require "fugit"

module HelperTypes
  # Medidor por ciclo (utility_meter do HA): consumo de um ponto acumulador
  # (kWh, m³) dentro do ciclo (hora, dia, semana, mês, trimestre, ano ou cron),
  # com dia de fechamento ("fatura no dia 12") e tarifas opcionais.
  #
  # Valor = consumo do ciclo (todas as tarifas). Atributos: `tariff` (ativa),
  # `tariffs` ({tarifa → consumo no ciclo}), `last_period` (o ciclo anterior)
  # e `period_start`. Origem que volta para baixo (aparelho reiniciou e zerou)
  # conta a leitura nova inteira como consumo, sem perder nem descontar nada.
  # Origem fora do ar não conta; na volta, a diferença entra de uma vez.
  # Comandos: "Zerar o ciclo" (reset) e "Trocar a tarifa" (select).
  class UtilityMeter < Plugin
    CYCLES = { "none" => "Sem ciclo (só zera à mão)", "hour" => "A cada hora", "day" => "Diário", "week" => "Semanal (segunda-feira)",
               "month" => "Mensal", "quarter" => "Trimestral", "year" => "Anual", "cron" => "Cron (avançado)" }.freeze
    # Ciclo → cron (%d = dia de fechamento).
    CRONS = { "hour" => "0 * * * *", "day" => "0 0 * * *", "week" => "0 0 * * 1", "month" => "0 0 %d * *",
              "quarter" => "0 0 %d 1,4,7,10 *", "year" => "0 0 %d 1 *" }.freeze
    MAX_TARIFFS = 10
    LABELS = { "reset" => "Zerar o ciclo", "select" => "Trocar a tarifa" }.freeze

    describe key: "utility_meter", title: "Medidor por ciclo", icon: "lightning-bolt", capability: "measure",
             description: "Consumo de um medidor (kWh, m³) por dia, mês ou ciclo da fatura, com tarifas: energia do mês desde o dia 12."
    fields %i[source cycle day cron tariffs_text]

    def self.assign(point, form)
      src = numeric_source!(point, form) or return
      cycle = form["cycle"].presence_in(CYCLES.keys) || point.address["cycle"] || "month"
      day = (number(form["day"]) || point.address["day"] || 1).to_i
      cron = form.key?("cron") ? form["cron"].to_s.squish : point.address["cron"].to_s
      tariffs = form.key?("tariffs_text") ? form["tariffs_text"].to_s.split(/[,\n]/).map(&:strip).compact_blank.uniq : point.options.to_a
      point.data_type = "decimal"
      point.writable = true
      point.unit = src.unit
      point.options = tariffs
      point.address = point.address.merge("cycle" => cycle, "day" => day, "cron" => (cron if cycle == "cron")).compact
      return point.errors.add(:base, "Dia de fechamento de 1 a 28.") unless day.between?(1, 28)
      return point.errors.add(:base, "Até #{MAX_TARIFFS} tarifas.") if tariffs.size > MAX_TARIFFS

      point.errors.add(:base, "Cron inválido (5 campos: minuto hora dia mês dia-da-semana).") if cycle == "cron" && !cron_for(point)
    end

    def self.sourced? = true
    def self.clocked? = true
    def self.initial_value(_point) = 0.0
    def self.commands(point) = point.options.present? ? %w[reset select] : %w[reset]
    def self.command_labels = LABELS
    def self.actions(_point) = %w[reset]

    def self.new_value(cmd)
      return 0.0 if cmd.command == "reset"

      cmd.value.to_s.presence_in(cmd.point.options.to_a) || invalid!("Tarifa desconhecida.")
      cmd.point.value
    end

    # Não se escreve valor de fora: ele vem da origem.
    def self.check(_point, _value) = invalid!("O medidor lê da origem; use Zerar ou Trocar a tarifa.")

    # Cron do ciclo no fuso do local (nil = sem ciclo ou cron inválido).
    def self.cron_for(point)
      a = point.address
      text = a["cycle"] == "cron" ? a["cron"].to_s : format(CRONS[a["cycle"]] || (return nil), a["day"].to_i.clamp(1, 28))
      return if text.split.size != 5

      Fugit::Cron.parse("#{text} #{point.site.timezone}")
    end

    # Início do ciclo em que `now` está (nil = sem ciclo).
    def self.period_start(point, now) = cron_for(point)&.previous_time(now + 1)&.to_t&.in_time_zone(point.site.timezone)

    def self.refresh!(point, now = Time.current)
      rollover!(point, now)
      v = reading(source(point)) or return
      last = state(point)["last"]
      delta = last.nil? ? 0.0 : (v >= last ? v - last : v) # desceu = o aparelho zerou: a leitura nova é o que andou
      save_state!(point, { "last" => v })
      add!(point, delta) if delta.positive? || point.value.nil?
    end

    def self.tick(point, now) = rollover!(point, now)

    def self.execute(point, command, value)
      refresh!(point) # o que andou até agora fica na tarifa e no ciclo de antes
      a = point.attrs.to_h
      if command == "select"
        point.report_attrs!(a.merge("tariff" => value.to_s))
      else
        close!(point, Time.current)
      end
    end

    def self.add!(point, delta)
      a = point.attrs.to_h
      tariff = a["tariff"].presence_in(point.options.to_a) || point.options.to_a.first
      tariffs = point.options.to_a.to_h { |t| [ t, a.dig("tariffs", t).to_f + (t == tariff ? delta : 0) ] }.transform_values { |x| x.round(6) }
      point.report_attrs!(a.merge("tariff" => tariff, "tariffs" => tariffs.presence, "period_start" => a["period_start"] || Time.current.iso8601).compact)
      point.report!((point.value.to_f + delta).round(6))
    end

    # Virou o ciclo: o valor vai para `last_period` e recomeça do zero.
    def self.rollover!(point, now)
      start = period_start(point, now) or return
      known = point.attrs.to_h["period_start"]
      return point.report_attrs!(point.attrs.to_h.merge("period_start" => start.iso8601)) if known.nil?

      close!(point, start) if start > Time.zone.parse(known)
    end

    def self.close!(point, start)
      a = point.attrs.to_h
      tariffs = a["tariffs"]&.transform_values { 0.0 }
      point.report_attrs!(a.merge("last_period" => point.value.to_f, "tariffs" => tariffs, "period_start" => start.iso8601).compact)
      point.report!(0.0)
    end

    def self.summary(point)
      cycle = CYCLES[point.address["cycle"]].to_s
      cycle += " · fecha dia #{point.address['day']}" if %w[month quarter year].include?(point.address["cycle"]) && point.address["day"].to_i > 1
      cycle += " · #{point.address['cron']}" if point.address["cycle"] == "cron"
      [ cycle, ("tarifas: #{point.options.join(', ')}" if point.options.present?) ].compact.join(" · ")
    end
  end
end
