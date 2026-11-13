module Api
  module V1
    # Câmeras no app (cameras2): a tela de Câmeras nativa, o ao vivo fora de casa por HLS
    # (o `video_player` do app toca o link assinado de `/cameras/:id/hls/<token>/…`, que
    # passa pelo Rails como o MSE da web) e a linha do tempo/reprodução do DVR.
    #
    #   GET    /sites/:site_id/cameras         câmeras do local + o que cada uma faz
    #   GET    /cameras/:id/hls                {url} do ao vivo (caminho a partir do servidor)
    #   GET    /cameras/:id/timeline?day=      gravações e eventos do dia (Cameras::Timeline)
    #   POST   /cameras/:id/playback           {start, replace?} → {stream, start, url}
    #   DELETE /cameras/:id/playback?stream=   para a reprodução
    class CamerasController < BaseController
      self.key_actions = { index: "read", timeline: "read" }

      before_action :load_camera, except: :index

      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        render_data(Cameras.for_site(site).map { |p| item(p) })
      end

      def hls
        render_data({ url: camera_hls_master_path(@point, Cameras::HlsToken.generate(@point, current_user, @point.id)) })
      end

      def timeline
        render_data(Cameras::Timeline.for(@point, params[:day]))
      end

      def playback
        zone = Cameras::Playback.zone(@point)
        from = begin
          zone.parse(params[:start].to_s)
        rescue ArgumentError
          nil
        end
        if from.nil? || from > Time.current || from < Cameras::Timeline::MAX_DAYS.days.ago
          return render_error(:invalid_parameter, I18n.t("cameras.playback.bad_time"), status: :unprocessable_content)
        end

        name = Drivers::Go2rtc.playback!(@point, from, user: current_user, replace: params[:replace])
        render_data({ stream: name, start: from.iso8601, url: camera_hls_master_path(@point, Cameras::HlsToken.generate(@point, current_user, name)) })
      rescue Drivers::Go2rtc::Error => e
        render_error(:camera_unavailable, e.message, status: :service_unavailable)
      end

      def stop_playback
        Drivers::Go2rtc.stop_playback!(params[:stream].to_s, user: current_user)
        head :no_content
      end

      private

      def viewer_allowed? = true

      def load_camera
        @point = Point.find(params[:id])
        raise ActiveRecord::RecordNotFound unless Cameras.camera?(@point)

        authorize_site!(@point.site, :view)
      end

      def item(p)
        { id: p.id, name: p.name, device: p.device.name, area: p.area&.name, quality: p.quality, features: Cameras.features(p) }
      end
    end
  end
end
