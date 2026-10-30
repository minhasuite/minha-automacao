# Agendas (F9): leitura de ICS (o link secreto do Google Agenda ou qualquer
# .ics) e o estado de um ponto `calendar` a partir dos eventos guardados nele
# (`address["events"]`: [{summary, start, end, all_day, location}], ISO 8601,
# de ontem até 31 dias). Gatilhos e condição da DSL leem daqui; a integração
# (Integrations::CalendarPlugin) busca e grava.
#
# ponytail: ICS com o essencial (VEVENT, DTSTART/DTEND/DURATION, TZID, dia
# inteiro, RRULE DAILY/WEEKLY/MONTHLY/YEARLY com INTERVAL/COUNT/UNTIL/BYDAY,
# EXDATE, RECURRENCE-ID e CANCELLED). BYMONTHDAY/BYSETPOS ("2ª terça") ficam
# só na primeira data; usar uma gem de recorrência se aparecer agenda assim.
module Calendars
  PAST = 1.day
  AHEAD = 31.days
  MAX_EVENTS = 200
  MAX_STEPS = 5000
  DAYS = %w[SU MO TU WE TH FR SA].freeze

  module_function

  def window(now = Time.current) = [ now - PAST, now + AHEAD ]

  # Texto ICS → eventos no formato do ponto, ordenados, dentro de [from, to).
  def parse_ics(text, zone, from:, to:)
    raw = vevents(text.to_s)
    overrides = raw.select { |v| v["RECURRENCE-ID"] }
    moved = overrides.to_set { |v| [ prop(v, "UID"), time(v["RECURRENCE-ID"].first, zone)&.to_i ] }
    list = raw.flat_map do |v|
      next [] if prop(v, "STATUS") == "CANCELLED"

      occurrences(v, zone, from, to).reject { |s, _| !v["RECURRENCE-ID"] && moved.include?([ prop(v, "UID"), s.to_i ]) }.map do |s, e|
        { "summary" => text_value(prop(v, "SUMMARY")).presence || "(sem título)", "start" => s.iso8601, "end" => e.iso8601,
          "all_day" => date?(v["DTSTART"].first), "location" => text_value(prop(v, "LOCATION")).presence }.compact
      end
    end
    list.sort_by { |e| e["start"] }.first(MAX_EVENTS)
  end

  def calendar_name(text) = text_value(text.to_s[/^X-WR-CALNAME:(.*)$/, 1].to_s.strip).presence

  # {"NOME" => [[valor, {parâmetros}], ...]} por VEVENT (linhas dobradas já unidas).
  def vevents(text)
    events = []
    cur = nil
    text.gsub(/\r?\n[ \t]/, "").split(/\r?\n/).each do |line|
      if line == "BEGIN:VEVENT" then cur = {}
      elsif line == "END:VEVENT"
        events << cur if cur
        cur = nil
      elsif cur && line.include?(":")
        head, value = line.split(":", 2)
        name, *params = head.split(";")
        (cur[name.upcase] ||= []) << [ value, params.to_h { |p| p.split("=", 2) } ]
      end
    end
    events
  end

  def prop(v, name) = v[name]&.first&.first
  def text_value(s) = s.to_s.gsub("\\n", "\n").gsub(/\\([,;\\])/, '\1')
  def date?(entry) = entry[1]["VALUE"] == "DATE" || entry[0].match?(/\A\d{8}\z/)

  # [valor, params] → Time no fuso (Z = UTC; TZID; flutuante = fuso do local; data = 0h).
  def time(entry, zone)
    value, params = entry
    tz = (params["TZID"] && ActiveSupport::TimeZone[params["TZID"].delete('"')]) || zone
    return tz.parse(value) if value.match?(/\A\d{8}\z/)

    m = value.match(/\A(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)(Z?)\z/) or return nil
    args = m.captures.first(6).map(&:to_i)
    m[7] == "Z" ? Time.utc(*args).in_time_zone(zone) : tz.local(*args)
  rescue ArgumentError
    nil
  end

  def duration(s)
    m = s.to_s.match(/\AP(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/) or return 0
    (m[1].to_i * 7 * 86_400) + (m[2].to_i * 86_400) + (m[3].to_i * 3600) + (m[4].to_i * 60) + m[5].to_i
  end

  # [[início, fim], ...] das ocorrências que tocam [from, to).
  def occurrences(v, zone, from, to)
    start = v["DTSTART"] && time(v["DTSTART"].first, zone) or return []
    finish = (v["DTEND"] && time(v["DTEND"].first, zone)) || (start + (v["DURATION"] ? duration(prop(v, "DURATION")) : (date?(v["DTSTART"].first) ? 1.day : 0)))
    length = [ finish - start, 0 ].max
    rule = prop(v, "RRULE")
    starts = rule && !v["RECURRENCE-ID"] ? expand(start, rule, zone, to) : [ start ]
    skip = Array(v["EXDATE"]).flat_map { |val, params| val.split(",").map { |x| time([ x, params ], zone)&.to_i } }.to_set
    starts.reject { |s| skip.include?(s.to_i) }.filter_map { |s| [ s, s + length ] if s < to && s + [ length, 1 ].max > from }
  end

  def expand(start, rule, zone, to)
    r = rule.split(";").to_h { |p| p.split("=", 2) }
    step = [ r["INTERVAL"].to_i, 1 ].max
    count = r["COUNT"]&.to_i
    until_at = r["UNTIL"] && time([ r["UNTIL"], {} ], zone)
    stop = [ to, until_at && (until_at + 1) ].compact.min
    days = r["BYDAY"].to_s.split(",").filter_map { |d| DAYS.index(d[-2..]) } if r["FREQ"] == "WEEKLY"
    out = []
    n = 0
    MAX_STEPS.times do
      base = advance(start, r["FREQ"], step * n) or break
      break if base >= stop

      list = days.present? ? days.map { |d| base.beginning_of_week(:sunday) + d.days + (start - start.beginning_of_day) }.sort.select { |t| t >= start } : [ base ]
      list.each do |t|
        break if t >= stop || (count && out.size >= count)

        out << t
      end
      break if count && out.size >= count

      n += 1
    end
    out
  end

  def advance(t, freq, n)
    case freq
    when "DAILY" then t + n.days
    when "WEEKLY" then t + n.weeks
    when "MONTHLY" then t + n.months
    when "YEARLY" then t + n.years
    end
  end

  # --- Ponto ---------------------------------------------------------------

  def events(point) = Array(point.address["events"])

  # Evento acontecendo agora (com filtro opcional no título).
  def current(point, now = Time.current, contains: nil)
    events(point).find { |e| match?(e, contains) && Time.zone.parse(e["start"]) <= now && now < Time.zone.parse(e["end"]) }
  end

  # Valor do ponto: o evento de agora ou o próximo (nil = nenhum na janela).
  def value_for(point, now = Time.current)
    e = current(point, now) || events(point).find { |x| Time.zone.parse(x["start"]) > now }
    e&.merge("now" => Time.zone.parse(e["start"]) <= now)
  end

  def match?(e, contains) = contains.blank? || e["summary"].to_s.downcase.include?(contains.to_s.downcase)

  # Grava os eventos e o valor (chamado pela leitura e a cada minuto).
  def store!(point, list = events(point), now = Time.current)
    point.update!(address: point.address.merge("events" => list)) if list != events(point)
    v = value_for(point, now)
    point.report!(v) if v != point.value || point.quality != "good"
  end

  # A cada minuto: o "agora/próximo" muda com o relógio, sem nova leitura.
  def tick(now = Time.current)
    ActsAsTenant.without_tenant do
      Point.where(capability: "calendar").find_each do |p|
        ActsAsTenant.with_tenant(p.tenant) { Automations.safely { store!(p, events(p), now) } }
      end
    end
  end
end
