module Dashboards
  module Widgets
    # Câmera (F8): quadro periódico e "Ao vivo" (WebRTC) do ponto `stream` do go2rtc.
    class CameraWidget < Base
      describe type: "camera", label: "Câmera", required: %w[bind], bind: true

      def self.data(r, w, binds) = GroupWidget.data(r, w, binds)
      def self.attrs(p, site = nil) = super.merge("live" => true)

      def self.auto_widget(point, id)
        return unless point.capability == "stream" && point.device.driver == "go2rtc"

        { "id" => id, "type" => type, "bind" => point.id, "live" => true, "span" => { "mobile" => 12, "tablet" => 6, "desktop" => 6 } }
      end
    end
  end
end
