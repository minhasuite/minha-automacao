module Api
  module V1
    # Ferramentas de desenvolvedor (Pacote 3, DevTools), só administrador ou
    # dono (token do app; chave de integração não entra). "Executar ação" é o
    # POST /points/:id/commands de sempre.
    class DevToolsController < BaseController
      before_action :load_site

      # GET /sites/:site_id/dev/states?q=&capability=
      def states = render_data(DevTools.states(@site, q: params[:q], capability: params[:capability]).map { |p| DevTools.state_json(p) })

      # POST /sites/:site_id/dev/states/:point_id { value } — só helper.
      def set_state
        point = DevTools.set_helper!(@site.points.find(params[:point_id]), params.require(:value))
        render_data(DevTools.state_json(point))
      end

      # POST /sites/:site_id/dev/template { template, mode: liquid|expr }
      def template
        result, error = DevTools.render(@site, params.require(:template), mode: params[:mode])
        return render_error(:invalid_template, error, status: :unprocessable_content) if error

        render_data({ "result" => result })
      end

      # POST /sites/:site_id/dev/events { event, data }
      def fire_event
        render_data({ "event" => DevTools.fire!(@site, params.require(:event), params[:data].respond_to?(:to_unsafe_h) ? params[:data].to_unsafe_h : params[:data]) })
      rescue ArgumentError => e
        render_error(:invalid_parameter, e.message, status: :unprocessable_content)
      end

      private

      def load_site
        return require_admin! unless DevTools.admin?(current_user)

        @site = Site.find(params[:site_id])
        authorize_site!(@site, :view)
      end
    end
  end
end
