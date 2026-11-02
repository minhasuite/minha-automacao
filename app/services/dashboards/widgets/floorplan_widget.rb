module Dashboards
  module Widgets
    # Planta baixa interativa (uiweb): camadas (andares), cada uma com a
    # imagem de fundo (enviada no editor ou link), os pontos posicionados em %
    # (x, y) e os cômodos (retângulos em %) que abrem a área. O ícone do ponto
    # acende com o estado e a cor reais (irmão `color` do aparelho) e alterna
    # com um toque; o modo "noite" escurece a planta e deixa as luzes brilhando.
    #
    #   { "type": "floorplan", "layers": [ { "id": "l1", "title": "Térreo", "image": "/rails/...",
    #     "pins": [ { "point": "<id>", "x": 12.5, "y": 40 } ],
    #     "rooms": [ { "area": "<id>", "x": 0, "y": 0, "w": 40, "h": 50 } ] } ] }
    class FloorplanWidget < Base
      describe type: "floorplan", label: "Planta baixa", icon: "map", required: %w[layers]

      MAX_LAYERS = 8
      MAX_PINS = 80
      MAX_ROOMS = 40
      IMAGE = %r{\A(https://|/)[^"'()\s<>]+\z}

      def self.form = "web/dashboards/widget_forms/floorplan"
      def self.permit = [ { "layers" => [ "id", "title", "image", "upload", "remove", { "pins" => %w[point x y remove] }, { "rooms" => %w[area x y w h remove] } ] } ]

      def self.errors(w)
        layers = w["layers"]
        return [ "layers precisa ser uma lista de 1 a #{MAX_LAYERS} camadas" ] unless layers.is_a?(Array) && layers.size.between?(1, MAX_LAYERS) && layers.all?(Hash)

        layers.each_with_index.flat_map do |l, i|
          where = "camada #{i + 1}"
          e = []
          e << "#{where}: imagem precisa ser um link https:// ou /" if l.key?("image") && !l["image"].to_s.match?(IMAGE)
          pins = l["pins"] || []
          rooms = l["rooms"] || []
          e << "#{where}: pins precisa ser uma lista de até #{MAX_PINS}" unless pins.is_a?(Array) && pins.size <= MAX_PINS
          e << "#{where}: rooms precisa ser uma lista de até #{MAX_ROOMS}" unless rooms.is_a?(Array) && rooms.size <= MAX_ROOMS
          e << "#{where}: ponto precisa de point e x/y de 0 a 100" unless Array(pins).all? { |pin| pin.is_a?(Hash) && pin["point"].is_a?(String) && pct?(pin, %w[x y]) }
          e << "#{where}: cômodo precisa de area e x/y/w/h de 0 a 100" unless Array(rooms).all? { |r| r.is_a?(Hash) && r["area"].is_a?(String) && pct?(r, %w[x y w h]) }
          e
        end
      end

      def self.pct?(h, keys) = keys.all? { |k| h[k].is_a?(Numeric) && h[k].between?(0, 100) }

      def self.data(r, w, _binds)
        deps = []
        areas = r.site.areas.index_by(&:id)
        views = Array(r.definition["views"])
        layers = Array(w["layers"]).map do |l|
          pins = Array(l["pins"]).filter_map do |pin|
            p = r.use(r.point(pin["point"])) or next
            color = r.use(color_point(r, p))
            deps.push(p, color)
            { "point_id" => p.id, "x" => pin["x"], "y" => pin["y"], "color_id" => color&.id }.compact
          end
          rooms = Array(l["rooms"]).filter_map do |room|
            area = areas[room["area"]] or next
            lights = r.points.select { |p| p.effective_area_id == area.id && p.capability.in?(%w[onoff dimmer]) && !p.hidden }
            deps.concat(lights)
            room.slice("x", "y", "w", "h").merge("area_id" => area.id, "name" => area.name, "on" => lights.count { |p| p.value == true || (p.value.is_a?(Numeric) && p.value.positive?) },
                                                  "view_id" => views.find { |v| v["area"] == area.id }&.dig("id"))
          end
          { "id" => l["id"], "title" => l["title"].presence || "Planta", "image" => l["image"], "pins" => pins, "rooms" => rooms }.compact
        end
        [ { "point_ids" => [], "layers" => layers }, deps.compact ]
      end

      # Formulário (camadas, pontos e cômodos indexados) → JSON. Linha sem
      # ponto/área ou marcada para remover some; camada vazia também.
      def self.attrs(p, _site = nil)
        layers = rows(p[:layers]).filter_map do |l|
          next if l[:remove] == "1"

          pins = rows(l[:pins]).filter_map { |x| { "point" => x[:point], "x" => coord(x[:x]), "y" => coord(x[:y]) } if x[:point].present? && x[:remove] != "1" }
          rooms = rows(l[:rooms]).filter_map do |x|
            next unless x[:area].present? && x[:remove] != "1"

            { "area" => x[:area], "x" => coord(x[:x], 10), "y" => coord(x[:y], 10), "w" => coord(x[:w], 30), "h" => coord(x[:h], 30) }
          end
          next if l[:title].blank? && l[:image].blank? && pins.empty? && rooms.empty?

          { "id" => l[:id].presence || "l-#{SecureRandom.alphanumeric(6).downcase}", "title" => l[:title].presence || "Planta",
            "image" => l[:image].presence, "pins" => pins, "rooms" => rooms }.compact
        end
        { "layers" => layers.presence }.compact
      end

      def self.rows(v)
        return [] if v.blank?

        v.respond_to?(:values) && !v.is_a?(Array) ? v.values : Array(v)
      end

      def self.coord(v, default = 50) = (number(v) || default).clamp(0, 100).then { |n| n.is_a?(Float) ? n.round(2) : n }
    end
  end
end
