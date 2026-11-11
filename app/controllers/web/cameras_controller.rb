module Web
  # Câmeras (F8): o navegador nunca fala com o go2rtc; o quadro (JPEG) e a
  # negociação WebRTC passam por aqui com o papel no local (qualquer papel vê).
  class CamerasController < ApplicationController
    MAX_SDP = 32.kilobytes

    before_action :load_camera

    # `?w=` = largura (celular); câmera de nuvem ou caída responde na hora (Drivers::Go2rtc.frame).
    def snapshot
      frame = Drivers::Go2rtc.frame(@point, width: params[:w])
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Frame-At"] = frame.at.iso8601
      response.headers["X-Camera-Offline"] = "1" if frame.offline
      send_data frame.jpeg, type: "image/jpeg", disposition: "inline"
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

    # ondaC2 (C10): gravação (modo, retenção, segundos por evento), PTZ e alto-falante da câmera.
    def settings
      authorize_site!(@point.site, :manage)
      Recordings.configure!(@point, params)
      supports = [ "record", ("ptz" if params[:ptz] == "1"), ("play_media" if params[:talk] == "1") ].compact
      @point.update!(writable: true, address: @point.address.merge("supports" => supports, "ptz" => supports.include?("ptz"), "talk" => supports.include?("play_media")))
      redirect_to point_path(@point), notice: t("cameras.saved")
    end

    private

    # Leitor (viewer) vê o painel e o que ele abre; comando e cadastro barram pelo papel.
    def viewer_allowed? = true

    def load_camera
      @point = Point.find(params[:id])
      raise ActiveRecord::RecordNotFound unless @point.capability == "stream" && (@point.device.driver == "go2rtc" || @point.address["image"] == "mqtt" || @point.address["on_demand"])

      authorize_site!(@point.site, :view)
    end
  end
end
