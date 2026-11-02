module Dashboards
  module Widgets
    # Ponto (F5): liga/desliga, valor, seleção, slider, campo e botões de ação.
    # O padrão do painel automático para ponto sem widget próprio.
    class TileWidget < Base
      describe type: "tile", label: "Ponto", icon: "light-bulb", required: %w[bind], params: %w[tap color], bind: true

      # `color_id`: o ponto de cor do aparelho (lâmpada colorida), para o brilho na cor real.
      def self.data(r, w, binds)
        color = r.use(color_point(r, binds.first))
        [ names(w, binds.first).merge("point_ids" => binds.map(&:id), "missing" => binds.empty? && w["bind"].present?, "color_id" => color&.id).compact, [ color ].compact ]
      end

      # Título do tile: o rótulo próprio; o automático do Início ("Aparelho · Ponto",
      # Generator#home_label) vira título + contexto pela regra de Point#display_names.
      def self.names(w, p)
        return { "title" => w["label"].presence || p&.name } unless p && w["label"] == "#{p.device.name} · #{p.name}"

        title, context = p.display_names
        { "title" => title, "context" => context }
      end

      def self.form = "web/dashboards/widget_forms/tile"
      def self.attrs(p, site = nil) = super.merge("features" => features(site&.points&.find_by(id: p[:bind]))).compact

      def self.features(point)
        return unless point
        return [ "slider" ] if point.capability.in?(%w[dimmer setpoint])

        [ "select" ] if point.capability == "enum"
      end
    end
  end
end
