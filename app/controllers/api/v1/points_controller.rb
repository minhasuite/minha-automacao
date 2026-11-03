module Api
  module V1
    # Pontos do dispositivo e comandos. Cadastro: técnico ou dono. Comando: o
    # papel mínimo depende do risco do ponto (SiteMembership::MIN_ROLE_BY_RISK).
    class PointsController < BaseController
      self.key_actions = { index: "read", site_index: "read", show: "read", history: "read", command: "command", talk: "command", write_value: "write" }
      TALK_MAX = 5.megabytes

      # ?view=app: cada ponto como no dashboard resolvido (texto, comandos,
      # can_command para o papel de quem pede), para o app desenhar os controles.
      def index
        device = Device.find(params[:device_id])
        role = authorize_site!(device.site, :view)
        records, meta = paginate(device.points.includes(:device, :tags).ordered)
        return render_data(records.map { |p| Dashboards::Resolver.point_json(p, role) }, meta: meta) if params[:view] == "app"

        render_data(PointSerializer.new(records, params: { reveal: reveal_sensitive? }).to_h, meta: meta)
      end

      # GET /sites/:site_id/points?view=app[&commandable=1] — todos os pontos do
      # local como o app desenha (widgets da tela inicial, atalhos e controles
      # do Android escolhem daqui); `commandable` = só os que este papel comanda.
      def site_index
        site = Site.find(params[:site_id])
        role = authorize_site!(site, :view)
        records, meta = paginate(site.points.includes(:device, :tags).ordered)
        list = records.map { |p| Dashboards::Resolver.point_json(p, role) }
        list = list.select { |p| p["can_command"] } if bool(params[:commandable])
        render_data(list, meta: meta)
      end

      # `?view=app`: o ponto como o app desenha (o widget da tela inicial relê por aqui).
      def show
        point = Point.find(params[:id])
        role = authorize_site!(point.site, :view)
        return render_data(Dashboards::Resolver.point_json(point, role)) if params[:view] == "app"

        render_data(PointSerializer.new(point, params: { reveal: reveal_sensitive? }).to_h)
      end

      def create
        device = Device.find(params[:device_id])
        authorize_site!(device.site, :manage)
        point = device.points.create!(params.permit(*PointSerializer::EDITABLE).merge(site_id: device.site_id))
        render_data(PointSerializer.new(point, params: { reveal: reveal_sensitive? }).to_h, status: :created)
      end

      def update
        point = Point.find(params[:id])
        authorize_site!(point.site, :manage)
        point.update!(params.permit(*PointSerializer::EDITABLE))
        render_data(PointSerializer.new(point, params: { reveal: reveal_sensitive? }).to_h)
      end

      def destroy
        point = Point.find(params[:id])
        authorize_site!(point.site, :manage)
        point.destroy!
        head :no_content
      end

      # POST /points/:id/commands { command, value?, client_uuid? } → 202 com o
      # comando (no driver virtual já vem `confirmed`; senão, GET /commands/:id).
      def command
        point = Point.find(params[:id])
        authorize_site!(point.site, :command, risk: point.risk)
        record = Points::Command.call(point, params.require(:command), params[:value], source: "api",
                                                                                      client_uuid: params[:client_uuid])
        render_data(CommandSerializer.new(record).to_h, status: :accepted)
      end

      # POST /points/:id/talk (audio = arquivo) — ondaC2 (C10): o "Falar" do app
      # (aperta, fala, solta): o áudio vira anexo de 1 dia e a câmera toca
      # pelo go2rtc (`play_media`). O navegador fala ao vivo pelo WebRTC.
      def talk
        point = Point.find(params[:id])
        authorize_site!(point.site, :command, risk: point.risk)
        audio = params.require(:audio)
        return render_error(:invalid_value, "Áudio grande demais.", status: :unprocessable_content) if audio.size > TALK_MAX

        _blob, path = Ai::Audio.store(audio.read, audio.content_type.presence || "audio/mp4", "falar-#{Time.current.to_i}")
        record = Points::Command.call(point, "play_media", MediaSources.public_url(path), source: "api")
        render_data(CommandSerializer.new(record).to_h, status: :accepted)
      end

      # POST /points/:id/value { value } — outro sistema escreve o valor de um
      # ponto virtual (ex.: preço no e-ink). Grava como leitura (Point#report!):
      # dispara automações, avisos e o tempo real como qualquer mudança.
      def write_value
        point = Point.find(params[:id])
        authorize_site!(point.site, :command, risk: point.risk)
        return render_error(:not_virtual, "Só ponto de dispositivo virtual recebe valor de fora.", status: :unprocessable_content) unless point.device.driver == "virtual"

        value = point.cast(params.require(:value).to_s)
        value = point.helper_type.check(point, value) if point.helper_type
        point.report!(value)
        render_data(PointSerializer.new(point, params: { reveal: reveal_sensitive? }).to_h)
      rescue Points::Command::Error => e
        render_error(e.code, e.message, status: :unprocessable_content)
      end

      # GET /points/:id/history?from=&to=&resolution=auto|raw|1h|1d (ISO 8601).
      def history
        point = Point.find(params[:id])
        authorize_site!(point.site, :view)
        h = Points::History.new(point, from: params[:from], to: params[:to], resolution: params[:resolution])
        items = h.raw? ? h.items.map { |r| { at: r.at, value: r.value&.to_f, value_text: r.value_text } } : h.items.map { |r| rollup(r) }
        render_data(items, meta: { from: h.from, to: h.to, resolution: h.resolution, truncated: h.truncated? })
      rescue ArgumentError => e
        render_error(:invalid_parameter, e.message, status: :bad_request)
      end

      # GET /points/:id/snapshot — quadro JPEG da câmera (ponto `stream` de
      # aparelho go2rtc) para o app (F7), igual ao /cameras/:id/quadro da web.
      # 503 camera_unavailable sem o go2rtc ou com a câmera fora.
      # POST /points/:id/webrtc (corpo = oferta SDP) → resposta SDP do go2rtc.
      # appweb2 (D3): câmera ao vivo nativa no app, o mesmo caminho da web.
      def webrtc
        point = Point.find(params[:id])
        raise ActiveRecord::RecordNotFound unless point.capability == "stream" && point.device.driver == "go2rtc"

        authorize_site!(point.site, :view)
        offer = request.raw_post.to_s
        return render_error(:invalid_parameter, "Oferta SDP inválida.", status: :unprocessable_content) unless offer.start_with?("v=0") && offer.bytesize <= 64.kilobytes

        render plain: Drivers::Go2rtc.webrtc(point, offer), content_type: "application/sdp"
      rescue Drivers::Go2rtc::Error => e
        render_error(:camera_unavailable, e.message, status: :service_unavailable)
      end

      def snapshot
        point = Point.find(params[:id])
        own = point.capability == "detection" # integ: quadro da detecção pelo plugin da câmera
        raise ActiveRecord::RecordNotFound unless own || (point.capability == "stream" && point.device.driver == "go2rtc")

        authorize_site!(point.site, :view)
        # app3: `?event=<id>` = quadro de uma detecção antiga (plugin com event_snapshots?); só na memória.
        point.value = point.value.merge("id" => params[:event]) if own && point.value.is_a?(Hash) && params[:event].to_s.match?(DetectionsController::EVENT_ID)
        jpeg = own ? Integrations.snapshot(point) : Drivers::Go2rtc.snapshot(point)
        return render_error(:camera_unavailable, "Sem quadro desta detecção.", status: :service_unavailable) if jpeg.nil?

        response.headers["Cache-Control"] = "no-store"
        send_data jpeg, type: "image/jpeg", disposition: "inline"
      rescue Drivers::Go2rtc::Error, Integrations::Error => e
        render_error(:camera_unavailable, e.message, status: :service_unavailable)
      end

      private

      # Leitor (viewer) vê o painel e o que ele abre; comando e cadastro barram pelo papel.
      def viewer_allowed? = true

      def rollup(r)
        { starts_at: r.starts_at, min: r.min&.to_f, max: r.max&.to_f, avg: r.avg&.to_f, sum: r.sum&.to_f,
          last: r.last&.to_f, count: r.count, on_seconds: r.on_seconds }
      end
    end
  end
end
