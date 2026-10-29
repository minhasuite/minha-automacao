module Web
  # Câmeras (F8): o navegador nunca fala com o go2rtc; o quadro (JPEG) e a
  # negociação WebRTC passam por aqui com o papel no local (qualquer papel vê).
  class CamerasController < ApplicationController
    MAX_SDP = 32.kilobytes

    before_action :load_camera

    def snapshot
      response.headers["Cache-Control"] = "no-store"
      send_data Drivers::Go2rtc.snapshot(@point), type: "image/jpeg", disposition: "inline"
    rescue Drivers::Go2rtc::Error => e
      render plain: e.message, status: :service_unavailable
    end

    def webrtc
      offer = request.raw_post.to_s
      return head(:unprocessable_content) if offer.blank? || offer.bytesize > MAX_SDP

      render plain: Drivers::Go2rtc.webrtc(@point, offer), content_type: "application/sdp"
    rescue Drivers::Go2rtc::Error => e
      render plain: e.message, status: :service_unavailable
    end

    private

    def load_camera
      @point = Point.find(params[:id])
      raise ActiveRecord::RecordNotFound unless @point.capability == "stream" && @point.device.driver == "go2rtc"

      authorize_site!(@point.site, :view)
    end
  end
end
