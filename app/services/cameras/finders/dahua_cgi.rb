module Cameras
  module Finders
    # Lista de gravações do DVR Dahua/Intelbras pela API HTTP (`mediaFileFind.cgi`):
    # factory.create → findFile (canal, início e fim do dia) → findNextFile em páginas →
    # close/destroy. Cada arquivo vira {from, to, events}; `Events[n]` (VideoMotion…) vem
    # do DVR quando o trecho foi gravado por evento.
    module DahuaCgi
      PAGE = 100
      MAX_PAGES = 30
      CGI = "/cgi-bin/mediaFileFind.cgi".freeze
      ITEM = /\Aitems\[(\d+)\]\.(\w+)(?:\[\d+\])?=(.*)\z/

      module_function

      def find(http, channel, from, to)
        obj = kv(http.get(path(action: "factory.create")))["result"].presence or raise Error, I18n.t("cameras.playback.bad_answer")
        begin
          begin
            http.get(path(action: "findFile", object: obj, "condition.Channel" => channel,
                          "condition.StartTime" => from.strftime("%Y-%m-%d %H:%M:%S"), "condition.EndTime" => to.strftime("%Y-%m-%d %H:%M:%S")))
          rescue Error => e
            # Dia sem nada gravado: o DVR responde 400 "Error" ao findFile.
            return [] if e.message == I18n.t("cameras.playback.http", code: "400")

            raise
          end
          items = []
          MAX_PAGES.times do
            found, page = parse(http.get(path(action: "findNextFile", object: obj, count: PAGE)), from.time_zone)
            items.concat(page)
            break if found < PAGE
          end
          items
        ensure
          %w[close destroy].each do |a|
            http.get(path(action: a, object: obj))
          rescue Error
            nil
          end
        end
      end

      # Espaço vira %20 (o DVR não entende o "+").
      def path(params) = "#{CGI}?" + params.map { |k, v| "#{k}=#{ERB::Util.url_encode(v.to_s)}" }.join("&")

      def kv(body) = body.to_s.lines.filter_map { |l| l.strip.split("=", 2) if l.include?("=") }.to_h

      def parse(body, zone)
        found = body[/^found=(\d+)/, 1].to_i
        items = Hash.new { |h, k| h[k] = { "events" => [] } }
        body.to_s.each_line do |line|
          m = ITEM.match(line.strip) or next
          i, key, val = m[1].to_i, m[2], m[3]
          case key
          when "StartTime" then items[i]["from"] = zone.parse(val)
          when "EndTime" then items[i]["to"] = zone.parse(val)
          when "Events" then items[i]["events"] << val
          end
        end
        [ found, items.values.select { |it| it["from"] && it["to"] } ]
      end
    end
  end
end
