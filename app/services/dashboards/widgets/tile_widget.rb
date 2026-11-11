module Dashboards
  module Widgets
    # Ponto (F5): liga/desliga, valor, seleção, slider, campo e botões de ação.
    # O padrão do painel automático para ponto sem widget próprio.
    class TileWidget < Base
      describe type: "tile", label: "Ponto", icon: "light-bulb", required: %w[bind], params: %w[tap color], bind: true
      texts en: { label: "Point" },
            es: { label: "Punto" }

      # `color_id`: o ponto de cor do aparelho (lâmpada colorida), para o brilho na cor real.
      # `level_id` (beleza, ideia 16): o ponto do brilho (o próprio dimmer, ou o dimmer irmão de
      # uma luz liga/desliga), para o tile acender na intensidade real.
      def self.data(r, w, binds)
        color = r.use(color_point(r, binds.first))
        level = r.use(level_point(r, binds.first))
        features, used = TileFeatures.resolve(r, w, binds.first)
        [ names(w, binds.first).merge("point_ids" => binds.map(&:id), "missing" => binds.empty? && w["bind"].present?, "color_id" => color&.id,
                                      "level_id" => level&.id, "features" => features.presence).compact, [ color, level, *used ].compact ]
      end

      def self.level_point(r, point)
        return unless point&.capability.in?(%w[onoff dimmer])
        return point if point.capability == "dimmer"

        r.points.find { |p| p.device_id == point.device_id && p.capability == "dimmer" && !p.disabled && TileFeatures::Brightness.match?(p) }
      end

      # Título do tile: o rótulo próprio; o automático do Início ("Aparelho · Ponto",
      # Generator#home_label) vira título + contexto pela regra de Point#display_names.
      def self.names(w, p)
        return { "title" => w["label"].presence || p&.name } unless p && w["label"] == "#{p.device.name} · #{p.name}"

        title, context = p.display_names
        { "title" => title, "context" => context }
      end

      def self.form = "web/dashboards/widget_forms/tile"
      def self.gestures? = true
      def self.permit = super + [ { "features" => [] } ]

      # Recursos escolhidos no editor (ondaB2); sem nenhum, os controles próprios do ponto.
      def self.attrs(p, site = nil)
        chosen = Array(p[:features]).compact_blank & TileFeatures.plugins.map(&:key)
        super.merge("features" => chosen.presence&.first(TileFeatures::MAX) || features(site&.points&.find_by(id: p[:bind]))).compact
      end

      def self.features(point)
        return unless point
        return [ "slider" ] if point.capability.in?(%w[dimmer setpoint])

        [ "select" ] if point.capability == "enum"
      end
    end
  end
end
