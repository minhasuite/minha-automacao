# Energia por aparelho (tela Energia, card "Gasto do mês por aparelho" e o
# aviso de consumo fora do normal). Não tem tabela: lê os rollups de hora
# (`reading_rollups`) pelo mesmo cálculo do widget de energia
# (`Dashboards::Energy`: medidor acumulado = diferença, potência = média × 1 h)
# e guarda a configuração do local em `sites.settings["energy"]`:
#
#   tariff_point  helper Tarifa (tarifa branca) ou Número em R$/kWh
#   tariff        tarifa fixa (sem ponto)
#   watch         regra do aviso: enabled, factor (× a média da hora),
#                 min_kwh (excesso mínimo), days (janela de aprendizado),
#                 min_days (dias de dado antes de avisar), ignore (aparelhos)
#
# O limiar é aprendido: a média do aparelho naquela hora do dia nos últimos
# `days` dias (hora sem leitura num dia com dado conta zero, como o motor da
# piscina parado de madrugada). Ver docs/energia.md.
module EnergyUse
  PERIODS = { "day" => "today", "week" => "week", "month" => "month" }.freeze
  WATCH = { "enabled" => false, "factor" => 2.0, "min_kwh" => 0.1, "days" => 28, "min_days" => 7, "ignore" => [] }.freeze

  module_function

  def settings(site) = site.settings.to_h["energy"].to_h
  def watch(site) = WATCH.merge(settings(site)["watch"].to_h)
  def tariff(site) = (v = settings(site)["tariff"]).is_a?(Numeric) && v >= 0 ? v.to_f : nil

  # Tarifa do local: o ponto escolhido; sem ponto nem tarifa fixa, o primeiro helper Tarifa.
  def tariff_point(site)
    id = settings(site)["tariff_point"]
    return site.points.find_by(id: id) if id.present?

    site.points.where(helper: "tariff").order(:name).first unless tariff(site)
  end

  def tariff_choices(site) = site.points.where(helper: %w[tariff number]).order(:name).select(&:numeric?)

  # {aparelho → pontos}: o de energia (kWh) de cada aparelho e, sem ele, o de
  # potência; helpers fora (não contar duas vezes um medidor por ciclo).
  def devices(site, points = nil)
    points ||= site.points.where(helper: nil, hidden: false, disabled: false).includes(:device).to_a
    points.select { |p| Dashboards::Energy.supported?(p) && p.device }.group_by(&:device)
          .transform_values { |pts| pts.select { |p| Dashboards::Energy.energy?(p) }.presence || pts }
  end

  def meter(site, points, period: "month", now: Time.current, tariff_point: tariff_point(site))
    Dashboards::Energy.new({ "period" => period, "tariff" => tariff(site) }, points, site, tariff_point: tariff_point, now: now)
  end

  # Consumo e custo por aparelho no período (dia, semana ou mês) e o mesmo
  # trecho do período anterior. Ordem: custo (com tarifa) ou kWh.
  def report(site, period: "month", now: Time.current)
    period = PERIODS.key?(period) ? period : "month"
    tp = tariff_point(site)
    rows = devices(site).map do |device, pts|
      m = meter(site, pts, period: PERIODS[period], now: now, tariff_point: tp)
      d = m.call
      from = Time.zone.parse(d["from"])
      elapsed = now - from
      prev_from = period == "month" ? from - 1.month : from - (Time.zone.parse(d["to"]) - from)
      prev_kwh, prev_cost = m.cost_between(prev_from, prev_from + elapsed)
      { "device" => device, "name" => device.name, "kwh" => d["kwh"], "cost" => d["cost"], "prev_kwh" => prev_kwh.round(2), "prev_cost" => prev_cost,
        "delta_pct" => delta(d["kwh"], prev_kwh), "from" => d["from"], "to" => d["to"], "label" => d["period_label"] }
    end
    priced = rows.any? { |r| r["cost"] }
    rows = rows.select { |r| r["kwh"].positive? || r["prev_kwh"].positive? }.sort_by { |r| -(priced ? r["cost"].to_f : r["kwh"]) }
    total = rows.sum { |r| r["kwh"] }
    rows.each { |r| r["pct"] = total.positive? ? (r["kwh"] / total * 100).round(1) : 0 }
    prev_total = rows.sum { |r| r["prev_kwh"] }
    { "period" => period, "label" => rows.first&.dig("label"), "rows" => rows, "priced" => priced, "total_kwh" => total.round(2),
      "total_cost" => (rows.sum { |r| r["cost"].to_f }.round(2) if priced), "prev_kwh" => prev_total.round(2),
      "prev_cost" => (rows.sum { |r| r["prev_cost"].to_f }.round(2) if priced), "delta_pct" => delta(total, prev_total) }
  end

  def delta(now, before) = before.to_f.positive? ? (((now.to_f - before) / before) * 100).round : nil

  # Hora `hour` (início, no fuso do local) do aparelho contra a média
  # aprendida da mesma hora nos dias anteriores.
  # → {kwh:, avg:, days:} ou nil sem dado bastante.
  def baseline(site, points, hour, cfg = watch(site))
    days = cfg["days"].to_i.clamp(7, 90)
    from = hour - days.days
    first = ReadingRollup.where(point_id: points.map(&:id), bucket: "1h", starts_at: from.utc...hour.utc).minimum(:starts_at)
    return unless first

    hourly = meter(site, points, now: hour + 1.hour).hourly(from, hour + 1.hour)
    first = first.in_time_zone(hour.time_zone)
    samples = (1..days).map { |n| hour - n.days }.select { |t| t >= first.beginning_of_hour }
    return if samples.size < cfg["min_days"].to_i.clamp(1, days)

    { "kwh" => hourly.fetch(hour, 0.0).round(3), "avg" => (samples.sum { |t| hourly.fetch(t, 0.0) } / samples.size).round(3), "days" => samples.size }
  end

  # Aparelhos com consumo fora do normal na última hora fechada (ou em `hour`):
  # kWh > factor × média da hora e o excesso ≥ min_kwh.
  def anomalies(site, now: Time.current, hour: nil)
    cfg = watch(site)
    zone = ActiveSupport::TimeZone[site.timezone] || Time.zone
    hour ||= now.in_time_zone(zone).beginning_of_hour - 1.hour
    ignore = Array(cfg["ignore"])
    devices(site).filter_map do |device, pts|
      next if ignore.include?(device.id)

      b = baseline(site, pts, hour, cfg) or next
      next unless b["kwh"] > b["avg"] * cfg["factor"].to_f && b["kwh"] - b["avg"] >= cfg["min_kwh"].to_f

      b.merge("device" => device, "name" => device.name, "hour" => hour)
    end
  end

  # Formulário da tela (técnico+). → mensagens de erro ([] = salvou).
  def update!(site, form)
    form = form.to_h.stringify_keys
    errors = []
    tp = form["tariff_point"].presence
    errors << I18n.t("energy.errors.tariff_point") if tp && tariff_choices(site).none? { |p| p.id == tp }
    fixed = Dashboards::Widgets::Base.number(form["tariff"]) if form["tariff"].present?
    errors << I18n.t("energy.errors.tariff") if form["tariff"].present? && !(fixed && fixed >= 0)
    factor = Dashboards::Widgets::Base.number(form["factor"]) || WATCH["factor"]
    errors << I18n.t("energy.errors.factor") unless factor.between?(1.1, 20)
    min_kwh = Dashboards::Widgets::Base.number(form["min_kwh"]) || WATCH["min_kwh"]
    errors << I18n.t("energy.errors.min_kwh") unless min_kwh.between?(0, 100)
    return errors if errors.any?

    ids = site.devices.where(id: Array(form["ignore"]).compact_blank).pluck(:id)
    w = watch(site).merge("enabled" => ActiveModel::Type::Boolean.new.cast(form["enabled"]) || false, "factor" => factor, "min_kwh" => min_kwh, "ignore" => ids)
    data = settings(site).merge("tariff_point" => tp, "tariff" => (fixed unless tp), "watch" => w).compact
    site.update!(settings: site.settings.to_h.merge("energy" => data))
    []
  end
end
