require "json"

# Sinais vitais do servidor (24/11/2026, docs/PROPOSTA-integrador.md, etapa 1): temperatura da CPU, internet e as
# quedas. Nasceu de duas noites na casa do piloto: o servidor (notebook) desligou por calor e ficou 4 h 45 sem rede,
# e nada disso apareceu em lugar nenhum.
#
# O `ServerWatchJob` (a cada minuto, no worker) chama `tick`: grava o batimento, confere a internet (`Internet.probe`,
# sem o cache) e a temperatura. Viram aviso ao dono e aos administradores (`Notifier`, kind "sistema"):
# - **ficou sem internet**, quando a rede volta (com início, fim e duração; durante a queda o push não sairia);
# - **ficou desligado**, no primeiro tick depois de ligar, se o batimento anterior ficou parado mais de OFF_GAP;
# - **quente**, com HOT_MINUTES ticks seguidos em ERROR_C ou mais (no máximo um aviso por HOT_EVERY).
# Estado em `storage/server-vitals.json` (volume `storage`: sobrevive a deploy e reinício).
module ServerVitals
  WARN_C = 85
  ERROR_C = 95
  HOT_MINUTES = 2
  HOT_EVERY = 1.hour
  OUTAGE_MIN = 2.minutes # queda menor que isso não vira aviso (um pacote perdido)
  OFF_GAP = 5.minutes # batimento parado por mais que isso = o servidor (ou o worker) ficou fora
  RECENT = 24.hours # queda mais nova que isso deixa a Saúde em "atenção"
  # Sensores de CPU conhecidos (Intel, AMD, Raspberry Pi, ACPI do notebook), pelo `name` do hwmon.
  SENSORS = %w[coretemp k10temp zenpower cpu_thermal soc_thermal acpitz].freeze

  module_function

  def path = Rails.root.join("storage/server-vitals.json")

  def state
    File.exist?(path) ? JSON.parse(File.read(path)) : {}
  rescue JSON::ParserError
    {}
  end

  def save!(data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  # Maior temperatura dos sensores de CPU, em °C (nil sem sensor: VM, contêiner sem /sys).
  def temperature(sys = Integrations::SystemPlugin::SYS)
    temps = Dir.glob(File.join(sys, "class/hwmon/hwmon*")).flat_map do |dir|
      name_file = File.join(dir, "name")
      next [] unless File.readable?(name_file) && SENSORS.include?(File.read(name_file).strip)

      Dir.glob(File.join(dir, "temp*_input")).filter_map { |f| Integer(File.read(f).strip, exception: false) }
    end
    if temps.empty? # Raspberry Pi e afins: só a zona térmica
      temps = Dir.glob(File.join(sys, "class/thermal/thermal_zone*/temp")).filter_map { |f| Integer(File.read(f).strip, exception: false) }
    end
    (temps.max / 1000.0).round if temps.any?
  rescue SystemCallError
    nil
  end

  def level(temp)
    return "ok" if temp.nil? || temp < WARN_C

    temp < ERROR_C ? "warn" : "error"
  end

  # Um minuto do vigia. `online`/`temp` entram nos specs; `now` também.
  def tick(now: Time.current, online: Internet.probe, temp: temperature)
    s = state
    notices = []
    last_beat = s["beat_at"] && Time.zone.parse(s["beat_at"])
    if last_beat && now - last_beat > OFF_GAP
      s["last_off"] = outage(last_beat, now)
      notices << [ :off, s["last_off"] ]
    end
    s["beat_at"] = now.iso8601

    if online
      if s["down_since"]
        from = Time.zone.parse(s.delete("down_since"))
        if now - from >= OUTAGE_MIN
          s["last_outage"] = outage(from, now)
          notices << [ :network, s["last_outage"] ]
        end
      end
    else
      s["down_since"] ||= now.iso8601
    end
    s["online"] = online

    s["temp"] = temp
    s["hot_ticks"] = temp && temp >= ERROR_C ? s["hot_ticks"].to_i + 1 : 0
    last_hot = s["hot_alert_at"] && Time.zone.parse(s["hot_alert_at"])
    if s["hot_ticks"] >= HOT_MINUTES && (last_hot.nil? || now - last_hot >= HOT_EVERY)
      s["hot_alert_at"] = now.iso8601
      notices << [ :hot, { "temp" => temp } ]
    end
    save!(s)
    notices.each { |kind, info| notify(kind, info) }
    s
  end

  # A queda mais nova (rede ou desligado): {"kind", "from", "to", "seconds"} ou nil.
  def last_outage(s = state)
    list = [ s["last_outage"]&.merge("kind" => "network"), s["last_off"]&.merge("kind" => "off") ].compact
    list.max_by { |o| o["to"].to_s }
  end

  def last_outage_text(s = state)
    o = last_outage(s) or return I18n.t("server_vitals.none")
    I18n.t("server_vitals.last.#{o['kind']}", duration: duration(o["seconds"]), **span(o))
  end

  def outage(from, to) = { "from" => from.iso8601, "to" => to.iso8601, "seconds" => (to - from).to_i }

  def notify(kind, info)
    title, body = case kind
    when :off then [ I18n.t("server_vitals.off.title", duration: duration(info["seconds"])), I18n.t("server_vitals.off.body", **span(info)) ]
    when :network then [ I18n.t("server_vitals.network.title", duration: duration(info["seconds"])), I18n.t("server_vitals.network.body", **span(info)) ]
    else [ I18n.t("server_vitals.hot.title", temp: info["temp"]), I18n.t("server_vitals.hot.body", temp: info["temp"], limit: ERROR_C) ]
    end
    tenants.each do |tenant|
      ActsAsTenant.with_tenant(tenant) do
        Notifier.notify!(kind: "sistema", title: title, body: body, data: { "url" => "/configuracoes/saude", "tag" => "servidor:#{kind}" })
      rescue Shadow::Blocked
        nil
      end
    end
  end

  def tenants = ActsAsTenant.without_tenant { Tenant.all.to_a }

  def span(info)
    from, to = Time.zone.parse(info["from"]), Time.zone.parse(info["to"])
    { from: I18n.l(from, format: "%d/%m %H:%M"), to: I18n.l(to, format: from.to_date == to.to_date ? "%H:%M" : "%d/%m %H:%M") }
  end

  # 285 min → "4 h 45 min"; 90 s → "1 min".
  def duration(seconds)
    d, rest = seconds.to_i.divmod(86_400)
    h, rest = rest.divmod(3600)
    m = [ rest / 60, 1 ].max
    [ ("#{d} d" if d.positive?), ("#{h} h" if h.positive?), ("#{m} min" unless d.positive? && h.positive?) ].compact.join(" ")
  end
end
