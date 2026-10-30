module Api
  module V1
    # Pontos do dispositivo e comandos. Cadastro: técnico ou dono. Comando: o
    # papel mínimo depende do risco do ponto (SiteMembership::MIN_ROLE_BY_RISK).
    class PointsController < BaseController
      self.key_actions = { index: "read", show: "read", history: "read", command: "command", write_value: "write" }

      def index
        device = Device.find(params[:device_id])
        authorize_site!(device.site, :view)
        records, meta = paginate(device.points.ordered)
        render_data(PointSerializer.new(records).to_h, meta: meta)
      end

      def show
        point = Point.find(params[:id])
        authorize_site!(point.site, :view)
        render_data(PointSerializer.new(point).to_h)
      end

      def create
        device = Device.find(params[:device_id])
        authorize_site!(device.site, :manage)
        point = device.points.create!(params.permit(*PointSerializer::EDITABLE).merge(site_id: device.site_id))
        render_data(PointSerializer.new(point).to_h, status: :created)
      end

      def update
        point = Point.find(params[:id])
        authorize_site!(point.site, :manage)
        point.update!(params.permit(*PointSerializer::EDITABLE))
        render_data(PointSerializer.new(point).to_h)
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

      # POST /points/:id/value { value } — outro sistema escreve o valor de um
      # ponto virtual (ex.: preço no e-ink). Grava como leitura (Point#report!):
      # dispara automações, avisos e o tempo real como qualquer mudança.
      def write_value
        point = Point.find(params[:id])
        authorize_site!(point.site, :command, risk: point.risk)
        return render_error(:not_virtual, "Só ponto de dispositivo virtual recebe valor de fora.", status: :unprocessable_content) unless point.device.driver == "virtual"

        point.report!(point.cast(params.require(:value).to_s))
        render_data(PointSerializer.new(point).to_h)
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

      private

      def rollup(r)
        { starts_at: r.starts_at, min: r.min&.to_f, max: r.max&.to_f, avg: r.avg&.to_f, sum: r.sum&.to_f,
          last: r.last&.to_f, count: r.count, on_seconds: r.on_seconds }
      end
    end
  end
end
