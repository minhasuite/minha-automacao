module Api
  module V1
    # Scripts (F8f): automação de `kind: "script"`, com campos. Mesmas regras
    # das automações (ver, criar, alterar, publicar). `POST /scripts/:id/run
    # {fields}` executa a versão publicada (202, com a execução): papel do
    # risco dos pontos do script e dos escolhidos nos campos; com chave de
    # integração, precisa da permissão "command" e do local na chave.
    class ScriptsController < AutomationsController
      self.key_actions = { index: "read", show: "read", runs: "read", run: "command" }

      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        render_data(site.scripts.ordered.map { |a| summary(a) })
      end

      # {name, mode, max_runs, area_id, description, icon, fields, definition, publish}
      def create
        site = Site.find(params[:site_id])
        authorize_site!(site, :manage)
        script = site.scripts.new(attrs.except(:enabled).merge(fields: fields_param))
        Automation.transaction do
          script.save!
          apply_definition(script) if params.key?(:definition)
        end
        render_data(full(script), status: :created)
      end

      def update
        script = find(:manage)
        Automation.transaction do
          script.update!(attrs.except(:enabled).merge(params.key?(:fields) ? { fields: fields_param } : {}))
          apply_definition(script) if params.key?(:definition)
        end
        render_data(full(script.reload))
      end

      def run
        script = find(:view)
        raise ActiveRecord::RecordInvalid, script.tap { |a| a.errors.add(:base, "Publique uma versão antes de executar.") } unless script.published?

        values = script.field_values(plain(:fields))
        risk = script.run_risk(values)
        authorize_site!(script.site, :command, risk: risk)
        raise ConfirmationRequired, "Este script comanda ponto crítico: envie confirm_critical: true." if risk == "critical" && !bool(params[:confirm_critical])

        run = script.run_script!(values, title: "API (#{current_user.name})", user: current_user)
        return render_error(:not_started, "Já está rodando (modo #{script.mode_label.downcase}).", status: :conflict) unless run

        render_data(AutomationRunSerializer.new(run).to_h, status: :accepted)
      rescue ArgumentError => e
        render_error(:invalid_fields, e.message.upcase_first, status: :unprocessable_content)
      end

      private

      def find(action)
        script = Automation.where(kind: "script").find(params[:id])
        authorize_site!(script.site, action)
        script
      end

      def attrs = params.permit(:name, :description, :mode, :max_runs, :area_id, :icon).to_h.symbolize_keys

      def fields_param
        raw = request.request_parameters["fields"]
        raw.is_a?(Array) ? raw.map { |f| f.is_a?(Hash) ? f.slice("name", "label", "type", "default", "required", "options") : f } : []
      end

      def summary(a) = super.merge(kind: a.kind, icon: a.icon, fields: a.fields).except(:enabled, :webhook)
    end
  end
end
