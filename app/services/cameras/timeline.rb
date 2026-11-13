# Linha do tempo da câmera (cameras2): o que o DVR/NVR gravou num dia, com os trechos
# de evento (movimento…) quando ele informa. Quem lista é o `finder` do perfil do
# fabricante (`config/device_maps/dvr.yml`) registrado em FINDERS (aberto/fechado:
# fabricante com outra API = módulo com `find(http, canal, de, até)` + linha aqui).
# Fica em cache (hoje 2 min, dias passados 1 h): a tela e o app não martelam o DVR.
module Cameras
  module Timeline
    FINDERS = { "dahua_cgi" => Finders::DahuaCgi, "isapi" => Finders::Isapi }.freeze
    KINDS = %w[motion person vehicle line region alarm event].freeze
    MAX_DAYS = 90

    module_function

    # day: "AAAA-MM-DD" no fuso do local (inválido ou futuro = hoje).
    def for(point, day)
      zone = Playback.zone(point)
      date = parse_day(day, zone)
      from = zone.local(date.year, date.month, date.day)
      to = from.end_of_day
      base = { "day" => date.iso8601, "from" => from.iso8601, "to" => to.iso8601, "time_zone" => zone.tzinfo.name,
               "available" => false, "recordings" => [], "events" => [], "error" => nil }
      _, profile = Playback.profile(point)
      finder = FINDERS[profile&.dig("finder").to_s]
      channel = Playback.channel(point)
      return base unless finder && channel

      ttl = date == zone.today ? 2.minutes : 1.hour
      items = Rails.cache.fetch("cameras:timeline:#{point.id}:#{date}", expires_in: ttl) do
        finder.find(http(point, profile), channel, from, to).map { |it| { "from" => it["from"].iso8601, "to" => it["to"].iso8601, "events" => it["events"] } }
      end
      base.merge("available" => true, **shape(items, profile, from, to, zone))
    rescue Error => e
      base.merge("available" => true, "error" => e.message)
    end

    def parse_day(day, zone)
      d = Date.iso8601(day.to_s)
      d.between?(zone.today - MAX_DAYS, zone.today) ? d : zone.today
    rescue Date::Error
      zone.today
    end

    def http(point, profile)
      d = point.device
      Http.new(host: d.address["host"], port: d.address["http_port"].presence || profile["http_port"] || 80,
               username: d.address["username"], password: d.credential)
    end

    # Gravado = união dos arquivos; evento = arquivo com evento, com o tipo do perfil.
    def shape(items, profile, from, to, zone)
      map = profile["events"].to_h
      list = items.filter_map do |it|
        a = [ zone.parse(it["from"]), from ].max
        b = [ zone.parse(it["to"]), to ].min
        [ a, b, it["events"] ] if b > a
      end.sort_by(&:first)
      recordings = list.each_with_object([]) do |(a, b), acc|
        if acc.any? && a <= acc.last[1] + 2
          acc.last[1] = [ acc.last[1], b ].max
        else
          acc << [ a, b ]
        end
      end
      events = list.filter_map do |a, b, names|
        next if names.blank?

        kind = names.lazy.map { |n| map[n] }.find(&:present?) || "event"
        kind = "event" unless KINDS.include?(kind)
        { "from" => a.iso8601, "to" => b.iso8601, "kind" => kind, "label" => I18n.t("cameras.timeline.kinds.#{kind}") }
      end
      { "recordings" => recordings.map { |a, b| { "from" => a.iso8601, "to" => b.iso8601 } }, "events" => events }
    end
  end
end
