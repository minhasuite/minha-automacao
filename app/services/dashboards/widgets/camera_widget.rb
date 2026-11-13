module Dashboards
  module Widgets
    # Câmera (F8): quadro periódico e "Ao vivo" (WebRTC) do ponto `stream` do go2rtc.
    # `autoplay: true` abre o ao vivo sozinho quando o card aparece na tela (a foto fica
    # enquanto ele não chega ou quando falha); `autoplay_max` = quantos ao vivo abertos
    # sozinhos cabem na página (padrão AUTOPLAY_MAX; os excedentes ficam na foto).
    class CameraWidget < Base
      AUTOPLAY_MAX = 8
      AUTOPLAY_MAX_RANGE = (1..16)

      describe type: "camera", label: "Câmera", required: %w[bind], params: %w[autoplay], bind: true
      texts en: { label: "Camera", autoplay: "autoplay must be true or false", autoplay_max: "autoplay_max must be from 1 to 16" },
            es: { label: "Cámara", autoplay: "autoplay debe ser true o false", autoplay_max: "autoplay_max debe ser de 1 a 16" },
            "pt-BR" => { autoplay: "autoplay precisa ser true ou false", autoplay_max: "autoplay_max precisa ser de 1 a 16" }

      def self.data(r, w, binds) = GroupWidget.data(r, w, binds)

      def self.errors(w)
        e = []
        e << text(:autoplay) if w.key?("autoplay") && ![ true, false ].include?(w["autoplay"])
        e << text(:autoplay_max) if w.key?("autoplay_max") && !(w["autoplay_max"].is_a?(Integer) && AUTOPLAY_MAX_RANGE.cover?(w["autoplay_max"]))
        e
      end

      def self.schema_props
        { "autoplay" => { "type" => "boolean" },
          "autoplay_max" => { "type" => "integer", "minimum" => AUTOPLAY_MAX_RANGE.min, "maximum" => AUTOPLAY_MAX_RANGE.max } }
      end

      def self.attrs(p, site = nil) = super.merge("live" => true, "autoplay" => p[:autoplay] == "1" || nil).compact
      # O formulário não mostra o intervalo nem o limite: editar pelo formulário não os perde.
      def self.keep(old, new) = old.slice("snapshot_interval", "autoplay_max").merge(new)
      def self.form = "web/dashboards/widget_forms/camera"

      def self.auto_widget(point, id)
        return unless point.capability == "stream" && point.device.driver == "go2rtc"

        { "id" => id, "type" => type, "bind" => point.id, "live" => true, "span" => { "mobile" => 12, "tablet" => 6, "desktop" => 6 } }
      end
    end
  end
end
