module Web
  # HLS da câmera (cameras2): para quem não toca MSE (app pelo `video_player`, Safari
  # antigo). O player não leva sessão nem cabeçalho: o caminho tem o token assinado
  # (`Cameras::HlsToken`: ponto, pessoa, stream) e os endereços relativos do go2rtc
  # (`hls/playlist.m3u8?id=…`) caem embaixo dele. O índice principal confere a pessoa e
  # o papel de novo, ocupa uma vaga do limite e prende a sessão do go2rtc ao token; os
  # pedaços só passam com a sessão presa a este token.
  class CameraHlsController < ActionController::Base # rubocop:disable Rails/ApplicationController
    SESSION_TTL = 60

    before_action :load_token

    def master
      user = ActsAsTenant.without_tenant { User.find_by(id: @token["u"]) }
      return head(:not_found) if user.nil? || user.disabled?

      ActsAsTenant.with_tenant(user.tenant) do
        point = Point.find_by(id: @token["p"])
        return head(:not_found) unless point && Cameras.camera?(point) && point.site.role_for(user)

        src = @token["s"]
        if src == point.id
          Drivers::Go2rtc.ready!(point, src)
        else
          owner = Drivers::Go2rtc.playback_owner(src)
          return head(:not_found) unless owner && owner["point"] == point.id && owner["user"] == user.id
        end
        body, sid = Drivers::Go2rtc.hls_master(src)
        return head(:bad_gateway) if sid.blank?
        return head(:too_many_requests) unless Cameras::Streams.acquire(user.id, "hls:#{sid}")

        Rails.cache.write(session_key(sid), params[:token], expires_in: SESSION_TTL)
        send_hls(body, "application/vnd.apple.mpegurl")
      end
    rescue Drivers::Go2rtc::Error
      head :service_unavailable
    end

    def file
      sid = request.query_parameters["id"].to_s # o :id do caminho é o ponto
      return head(:not_found) unless sid.match?(/\A\w{1,32}\z/) && Rails.cache.read(session_key(sid)) == params[:token]

      type = Drivers::Go2rtc::HLS_FILES[params[:file]] or return head(:not_found)
      if params[:file] == "playlist.m3u8"
        Rails.cache.write(session_key(sid), params[:token], expires_in: SESSION_TTL)
        Cameras::Streams.touch(@token["u"], "hls:#{sid}")
        Drivers::Go2rtc.touch_playback(@token["s"])
      end
      n = request.query_parameters["n"].to_s[/\A\d{1,9}\z/]
      send_hls(Drivers::Go2rtc.hls_file(params[:file], sid, n), type)
    rescue Drivers::Go2rtc::Error
      head :service_unavailable
    end

    private

    def load_token
      @token = Cameras::HlsToken.verify(params[:token])
      head(:not_found) unless @token
    end

    def session_key(sid) = "cameras:hls:#{sid}"

    def send_hls(body, type)
      response.headers["Cache-Control"] = "no-store"
      send_data body, type: type, disposition: "inline"
    end
  end
end
