module MediaSources
  # Rádios da internet pelo radio-browser.info (o Radio Browser do HA): as
  # mais votadas, as do país do local, por gênero e busca pelo nome.
  # Resposta guardada 10 min no cache.
  class RadioBrowser < Source
    API = "https://de1.api.radio-browser.info/json".freeze
    LIMIT = 60
    TAGS = %w[pop rock jazz classical news talk sertanejo mpb samba electronic lofi kids].freeze

    describe key: "radios", title: "Rádios", icon: "globe",
             description: "Milhares de rádios da internet: as mais ouvidas, as do seu país e por gênero."
    texts en: { title: "Radio", description: "Thousands of internet radio stations: most popular, from your country and by genre.",
                top: "Most voted", country: "From your country", genres: "By genre" },
          es: { title: "Radios", description: "Miles de radios de internet: las más escuchadas, las de tu país y por género.",
                top: "Más votadas", country: "De tu país", genres: "Por género" },
          "pt-BR" => { top: "Mais votadas", country: "Do seu país", genres: "Por gênero" }

    class << self
      def searchable? = true

      def browse(site, path, query: nil)
        return page(query, nil, stations("/stations/search", name: query)) if query.present?

        case path.to_s
        when "" then page(title, nil, [ item(id: "top", title: text(:top), kind: "folder"), item(id: "country", title: text(:country), kind: "folder"),
                                        item(id: "tags", title: text(:genres), kind: "folder") ])
        when "top" then page(text(:top), "", stations("/stations/topvote"))
        when "country" then page(text(:country), "", stations("/stations/bycountrycodeexact/#{ERB::Util.url_encode(site.country.presence || 'BR')}"))
        when "tags" then page(text(:genres), "", TAGS.map { |t| item(id: "tag/#{t}", title: t.capitalize, kind: "folder") })
        else
          tag = path.to_s.delete_prefix("tag/")
          page(tag.capitalize, "tags", stations("/stations/bytagexact/#{ERB::Util.url_encode(tag)}"))
        end
      end

      def stations(path, **params)
        get(path, params).filter_map do |s|
          next if s["stationuuid"].blank? || s["url_resolved"].blank?

          item(id: s["stationuuid"], title: s["name"].to_s.squish.truncate(80), kind: "radio", thumb: s["favicon"].presence&.then { |u| u if u.start_with?("https://") },
               subtitle: [ s["country"], s["tags"].to_s.split(",").first(2).join(", ") ].compact_blank.join(" · "))
        end
      end

      def media_url(_site, id) = station_url(id)
      def preview_url(_site, id) = station_url(id)

      def station_url(uuid)
        raise ArgumentError, "rádio inválida" unless uuid.to_s.match?(/\A[\h-]{36}\z/)

        get("/stations/byuuid/#{uuid}", {}).first&.dig("url_resolved") or raise ArgumentError, "rádio não encontrada"
      end

      def get(path, params)
        query = { limit: LIMIT, hidebroken: true, order: "votes", reverse: true }.merge(params.compact)
        url = "#{API}#{path}?#{query.to_query}"
        Rails.cache.fetch([ "radio_browser", url ], expires_in: 10.minutes) do
          res = SafeHttp.get(url, timeout: 10, headers: { "User-Agent" => "MinhaAutomacao/1.0" })
          raise ArgumentError, "radio-browser respondeu #{res.status}" if res.status >= 400

          JSON.parse(res.body)
        end
      rescue SafeHttp::Error, JSON::ParserError => e
        raise ArgumentError, e.message
      end
    end
  end
end
