module Web
  # Câmeras (F8): o navegador nunca fala com o go2rtc; o quadro (JPEG), a
  # negociação WebRTC e o MSE (cameras2, ao vivo fora de casa) passam por aqui com
  # o papel no local (qualquer papel vê). cameras2: tela própria (grade e câmera em
  # tela cheia com a linha do tempo do DVR e a reprodução).
  class CamerasController < ApplicationController
    include SitePick

    MAX_SDP = 32.kilobytes
    WS_KEY = %r{\A[A-Za-z0-9+/]{22}==\z}

    before_action :load_camera, except: :index

    # Grade de todas as câmeras do local, ao vivo automático.
    def index
      return redirect_to(sites_path) unless pick_site

      @cameras = Cameras.for_site(@site)
    end

    # Uma câmera grande: troca rápida (setas, teclado, gesto), falar e a linha do tempo.
    def show
      @cameras = Cameras.for_site(@point.site)
      i = @cameras.index { |c| c.id == @point.id } || 0
      @prev = @cameras[i - 1] if @cameras.size > 1
      @next = @cameras[(i + 1) % @cameras.size] if @cameras.size > 1
      @features = Cameras.features(@point)
      @day = Cameras::Timeline.parse_day(params[:dia], Cameras::Playback.zone(@point))
    end

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

    # `?pb=` = a reprodução do DVR desta pessoa (mesmo caminho do ao vivo).
    def webrtc
      offer = request.raw_post.to_s
      return head(:unprocessable_content) if offer.blank? || offer.bytesize > MAX_SDP

      render plain: Drivers::Go2rtc.webrtc(@point, offer, src: stream_src), content_type: "application/sdp"
    rescue Drivers::Go2rtc::Error => e
      render plain: e.message, status: :service_unavailable
    end

    # cameras2: MSE do go2rtc por WebSocket através do Rails (ao vivo fora de casa, onde
    # a mídia WebRTC na 8555 não chega). Mesma origem (nada de WebSocket aberto por
    # outro site com o cookie), uma vaga do limite por pessoa, conexão tomada do Puma.
    def mse
      key = request.headers["Sec-WebSocket-Key"].to_s
      return head(:bad_request) unless request.headers["Upgrade"].to_s.casecmp?("websocket") && key.match?(WS_KEY)
      return head(:forbidden) unless same_origin?

      hijack = request.env["rack.hijack"] or return head(:not_implemented)
      src = stream_src
      Drivers::Go2rtc.ready!(@point, src)
      slot = "ws:#{SecureRandom.hex(6)}"
      user_id = current_user.id
      return render(plain: t("cameras.too_many", n: Cameras::Streams.max), status: :too_many_requests) unless Cameras::Streams.acquire(user_id, slot)

      target = Drivers::Go2rtc.ws_target(src)
      io = hijack.call
      io = request.env["rack.hijack_io"] unless io.respond_to?(:write)
      wrap = ->(&blk) { -> { Rails.application.executor.wrap(&blk) } }
      Cameras::WsProxy.start(io, target, key,
                             on_touch: wrap.call { Cameras::Streams.touch(user_id, slot); Drivers::Go2rtc.touch_playback(src) },
                             on_close: wrap.call { Cameras::Streams.release(user_id, slot) })
      head :ok
    rescue Drivers::Go2rtc::Error => e
      render plain: e.message, status: :service_unavailable
    end

    # Link do HLS (Safari sem MSE): assinado, sem sessão (`Web::CameraHlsController`).
    def hls
      render json: { url: camera_hls_master_path(@point, Cameras::HlsToken.generate(@point, current_user, stream_src)) }
    end

    # Linha do tempo do dia (DVR): quadro da tela (turbo-frame) ou JSON.
    def timeline
      @timeline = Cameras::Timeline.for(@point, params[:dia])
      respond_to do |f|
        f.html { render partial: "web/cameras/timeline", locals: { point: @point, timeline: @timeline } }
        f.json { render json: @timeline }
      end
    end

    # Toca a gravação a partir de `inicio` (ISO 8601, ou "AAAA-MM-DD HH:MM:SS" no fuso do
    # local). `troca` = reprodução anterior desta pessoa (pular ±30 s cria outra).
    def playback
      zone = Cameras::Playback.zone(@point)
      from = begin
        zone.parse(params[:inicio].to_s)
      rescue ArgumentError
        nil
      end
      return render(json: { error: t("cameras.playback.bad_time") }, status: :unprocessable_content) if from.nil? || from > Time.current || from < Cameras::Timeline::MAX_DAYS.days.ago

      name = Drivers::Go2rtc.playback!(@point, from, user: current_user, replace: params[:troca])
      render json: { stream: name, start: from.iso8601, webrtc: camera_webrtc_path(@point, pb: name), mse: camera_mse_path(@point, pb: name),
                     hls: camera_hls_master_path(@point, Cameras::HlsToken.generate(@point, current_user, name)) }
    rescue Drivers::Go2rtc::Error => e
      render json: { error: e.message }, status: :service_unavailable
    end

    def stop_playback
      Drivers::Go2rtc.stop_playback!(params[:pb].to_s, user: current_user)
      head :no_content
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
      raise ActiveRecord::RecordNotFound unless Cameras.camera?(@point)

      authorize_site!(@point.site, :view)
      @site = @point.site
    end

    # O ponto ou a reprodução `?pb=` desta pessoa, desta câmera.
    def stream_src
      name = params[:pb].presence or return @point.id
      owner = Drivers::Go2rtc.playback_owner(name)
      raise ActiveRecord::RecordNotFound unless owner && owner["point"] == @point.id && owner["user"] == current_user.id

      Drivers::Go2rtc.touch_playback(name)
      name
    end

    def same_origin?
      origin = request.headers["Origin"].presence or return true
      URI(origin).host == request.host
    rescue URI::InvalidURIError
      false
    end
  end
end
