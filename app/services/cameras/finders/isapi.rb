require "rexml/document"

module Cameras
  module Finders
    # Lista de gravações do DVR/NVR Hikvision pela ISAPI (`/ISAPI/ContentMgmt/search`):
    # trilha = canal×100+1, páginas enquanto o aparelho responde MORE. O tipo do trecho
    # vem no `metadataDescriptor` (…/MOTION, …/timing); horário local com "Z" (Hikvision).
    module Isapi
      PAGE = 100
      MAX_PAGES = 30
      PLAIN = %w[timing cmr continuous allrecordtype].freeze

      module_function

      def find(http, channel, from, to)
        items = []
        MAX_PAGES.times do |n|
          doc = REXML::Document.new(http.post("/ISAPI/ContentMgmt/search", body(channel, from, to, n * PAGE)).sub(/\sxmlns="[^"]*"/, ""))
          doc.get_elements("//searchMatchItem").each do |it|
            a = time(it.elements["timeSpan/startTime"]&.text, from.time_zone)
            b = time(it.elements["timeSpan/endTime"]&.text, from.time_zone)
            kind = it.elements["metadataMatches/metadataDescriptor"]&.text.to_s.split("/").last.to_s
            items << { "from" => a, "to" => b, "events" => PLAIN.include?(kind.downcase) || kind.empty? ? [] : [ kind ] } if a && b
          end
          break unless doc.elements["//responseStatusStrg"]&.text.to_s.casecmp?("MORE")
        end
        items
      end

      def time(text, zone) = text.present? ? zone.parse(text.delete_suffix("Z")) : nil

      def body(channel, from, to, position)
        fmt = "%Y-%m-%dT%H:%M:%SZ"
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <CMSearchDescription>
            <searchID>#{SecureRandom.uuid.upcase}</searchID>
            <trackList><trackID>#{(channel * 100) + 1}</trackID></trackList>
            <timeSpanList><timeSpan><startTime>#{from.strftime(fmt)}</startTime><endTime>#{to.strftime(fmt)}</endTime></timeSpan></timeSpanList>
            <maxResults>#{PAGE}</maxResults>
            <searchResultPostion>#{position}</searchResultPostion>
            <metadataList><metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor></metadataList>
          </CMSearchDescription>
        XML
      end
    end
  end
end
