module Api
  module V1
    # Saúde do sistema para o app (a mesma de Configurações → Saúde): cada
    # verificação do registro `Health::CHECKS`, inclusive as personalizadas.
    # Só administradores; chave de integração não entra.
    class HealthController < BaseController
      before_action :require_admin!

      # GET /api/v1/health
      def show
        results = Health.run(current_user.tenant)
        render_data(results.map { |r| result_json(r) }, meta: { status: Health.worst(results.map(&:status)) })
      end

      private

      def result_json(r)
        { key: r.check.key, label: r.check.label, icon: r.check.icon, status: r.status,
          items: r.items.map { |i| { key: i.key, status: i.status, title: i.title, detail: i.detail, at: i.at, ignored: i.ignored, fix: i.fix } } }
      end
    end
  end
end
