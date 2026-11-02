module Api
  module V1
    # Serviço de uma ponte de exposição (integ; ex.: matter-bridge), com a
    # chave de integração gerada na tela da ponte:
    #   GET  /bridges/:key           → pontos expostos nos locais da chave, com o estado
    #   PUT  /bridges/:key/status    → situação (código de pareamento, pareada?)
    #   POST /bridges/:key/commands  {point_id, attribute, value} → comando no ponto
    class BridgesController < BaseController
      self.key_actions = { index: "read", status: "read", command: "command" }

      before_action :load_bridge

      def index
        render_data({ "devices" => Bridges.devices(@bridge, visible_sites) })
      end

      def status
        Bridges.report_status!(@bridge, current_user.tenant, params.permit(:qr, :manual, :commissioned, :fabrics, :port).to_h)
        head :no_content
      end

      def command
        point = Point.find(params.require(:point_id))
        authorize_site!(point.site, :command, risk: point.risk)
        record = Bridges.command!(@bridge, point, params.require(:attribute), params[:value])
        render_data(record && CommandSerializer.new(record).to_h, status: record ? :accepted : :ok)
      end

      private

      def load_bridge
        @bridge = Bridges[params[:key]] or render_error(:not_found, "Ponte desconhecida.", status: :not_found)
      end
    end
  end
end
