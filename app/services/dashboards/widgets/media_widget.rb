module Dashboards
  module Widgets
    # Mídia (Pacote 1; `media-control` do HA): situação, título, app e volume
    # do ponto, com os botões que o ponto aceita (`Points::Command.commands_for`,
    # cortado pelo `address.supports` do aparelho). Serve para qualquer ponto
    # com esses comandos: TV, Chromecast, Spotify e também a Echo (`speaker`,
    # que só tem o volume). Nada aqui pergunta a marca ou o driver.
    class MediaWidget < Base
      describe type: "media", label: "Mídia", icon: "desktop-computer", required: %w[bind], bind: true, auto: %w[media]

      FIELDS = %w[state title artist album app source volume muted].freeze
      CONTROLS = %w[on off previous resume pause next volume_down volume_up mute volume play_media].freeze

      def self.data(_r, _w, binds)
        point = binds.first or return [ { "point_ids" => [], "missing" => true }, [] ]

        v = point.value.is_a?(Hash) ? point.value : { "state" => point.value&.to_s }
        [ { "point_ids" => [ point.id ], "media" => v.slice(*FIELDS).compact, "controls" => Points::Command.commands_for(point) & CONTROLS }, [] ]
      end
    end
  end
end
