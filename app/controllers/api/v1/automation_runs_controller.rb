module Api
  module V1
    # Uma execução com o trace passo a passo (qualquer papel no local).
    class AutomationRunsController < BaseController
      def show
        run = AutomationRun.find(params[:id])
        authorize_site!(run.site, :view)
        render_data(AutomationRunSerializer.new(run).to_h)
      end
    end
  end
end
