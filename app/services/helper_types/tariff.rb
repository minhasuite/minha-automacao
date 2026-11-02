module HelperTypes
  # Tarifa de energia (paridade com o HA): preço do kWh fixo ou por horário,
  # como a tarifa branca (ponta, intermediária e fora de ponta) ou qualquer
  # bandeira/horário que a distribuidora use. As faixas são texto, uma por
  # linha: "Ponta 18:00-21:00 = 1,35" (o nome é opcional; faixa que passa da
  # meia-noite vale). Fora das faixas (e no fim de semana, se marcado) vale o
  # preço base. O valor do ponto é o preço de agora (o relógio dos helpers
  # refaz a cada minuto) e o painel de Energia pergunta `price_at` hora a hora.
  # ponytail: feriado nacional conta como dia útil; somar um calendário se a distribuidora cobrar.
  class Tariff < Plugin
    BAND = /\A(?:(?<label>.*?\S)\s+)?(?<from>\d{1,2}:\d{2})\s*(?:-|–|a|até)\s*(?<to>\d{1,2}:\d{2})\s*=\s*(?:R\$\s*)?(?<price>\d+(?:[.,]\d+)?)\z/i
    WHITE = "Ponta 18:00-21:00 = 1,35\nIntermediária 17:00-18:00 = 0,92\nIntermediária 21:00-22:00 = 0,92".freeze
    BASE_LABEL = "Fora de ponta".freeze

    describe key: "tariff", title: "Tarifa de energia", icon: "cash", capability: "measure",
             description: "Preço do kWh, fixo ou por horário (tarifa branca). O painel de Energia calcula o custo hora a hora."
    fields %i[base bands weekdays_only]

    def self.assign(point, form)
      point.writable = false
      point.data_type = "decimal"
      point.unit = "R$/kWh"
      base = number(form["base"])
      point.errors.add(:base, "Informe o preço base do kWh (R$).") unless base && base >= 0
      bands, bad = parse(form["bands"])
      point.errors.add(:base, "Faixa que não entendi: #{bad.first(3).join('; ')}. Use \"Ponta 18:00-21:00 = 1,35\".") if bad.any?
      point.address = point.address.merge("base" => base, "bands" => bands,
                                          "weekdays_only" => ActiveModel::Type::Boolean.new.cast(form.fetch("weekdays_only", "1")) || false)
    end

    # Texto → [faixas, linhas que não serviram].
    def self.parse(text)
      bad = []
      bands = text.to_s.lines.map(&:strip).compact_blank.first(12).filter_map do |line|
        m = BAND.match(line)
        from, to = m && [ m[:from], m[:to] ].map { |t| minutes(t) }
        next bad.push(line) && nil unless from && to && from != to

        { "label" => m[:label].presence, "from" => m[:from].rjust(5, "0"), "to" => m[:to].rjust(5, "0"), "price" => m[:price].tr(",", ".").to_f }
      end
      [ bands, bad ]
    end

    def self.minutes(hhmm)
      h, m = hhmm.split(":").map(&:to_i)
      h * 60 + m if h.between?(0, 24) && m.between?(0, 59) && h * 60 + m <= 1440
    end

    # Faixa que vale no instante (nil = preço base).
    def self.band_at(point, time)
      local = time.in_time_zone(ActiveSupport::TimeZone[point.site.timezone] || Time.zone)
      return if point.address["weekdays_only"] && (local.saturday? || local.sunday?)

      now = local.hour * 60 + local.min
      Array(point.address["bands"]).find do |b|
        from = minutes(b["from"])
        to = minutes(b["to"])
        from < to ? now >= from && now < to : now >= from || now < to
      end
    end

    def self.price_at(point, time) = (band_at(point, time)&.dig("price") || point.address["base"]).to_f

    def self.sourced? = true
    def self.clocked? = true
    def self.tick(point, now) = refresh!(point, now)

    def self.refresh!(point, now = Time.current)
      band = band_at(point, now)
      price = price_at(point, now)
      point.report!(price) if point.value != price
      label = band ? band["label"] || "Faixa #{band['from']}-#{band['to']}" : BASE_LABEL
      point.report_attrs!(point.attrs.to_h.merge("band" => label)) if point.attrs.to_h["band"] != label
    end

    def self.value_text(point)
      return unless point.value.is_a?(Numeric)

      "R$ #{format('%.2f', point.value).tr('.', ',')}/kWh · #{point.attrs.to_h['band'] || BASE_LABEL}"
    end

    def self.summary(point)
      bands = Array(point.address["bands"])
      base = "R$ #{format('%.2f', point.address['base'].to_f).tr('.', ',')}"
      bands.empty? ? "#{base}/kWh fixo" : "#{base} fora das faixas · #{bands.size} faixa(s)#{' em dias úteis' if point.address['weekdays_only']}"
    end
  end
end
