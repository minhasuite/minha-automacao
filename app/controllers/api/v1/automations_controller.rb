module Api
  module V1
    # Automações (F6, ESQUEMA-V1 §5 e §8). Ver a lista e as execuções:
    # qualquer papel no local. Criar, alterar, publicar, voltar versão,
    # simular e excluir: técnico ou dono. Publicar (ou executar) automação
    # que comanda ponto sensível/crítico exige o papel do risco e, no
    # crítico, `confirm_critical: true`. Formato em docs/automacoes.md.
    class AutomationsController < BaseController
      class ConfirmationRequired < StandardError; end

      rescue_from ConfirmationRequired do |e|
        render_error(:confirmation_required, e.message, status: :unprocessable_content)
      end

      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        render_data(site.automations.ordered.map { |a| summary(a) })
      end

      def show
        automation = find(:view)
        render_data(full(automation))
      end

      # {name, mode, max_runs, area_id, description, enabled, definition, publish}:
      # `definition` vai para o rascunho e é publicada (salvo `publish: false`).
      def create
        site = Site.find(params[:site_id])
        authorize_site!(site, :manage)
        automation = site.automations.new(attrs.except(:enabled))
        Automation.transaction do
          automation.save!
          apply_definition(automation)
          automation.update!(enabled: bool(params[:enabled])) if params.key?(:enabled)
        end
        render_data(full(automation), status: :created)
      end

      def update
        automation = find(:manage)
        Automation.transaction do
          automation.update!(attrs.except(:enabled))
          apply_definition(automation) if params.key?(:definition)
          automation.update!(enabled: bool(params[:enabled])) if params.key?(:enabled)
        end
        render_data(full(automation.reload))
      end

      def destroy
        automation = find(:manage)
        automation.destroy!
        head :no_content
      end

      def publish
        automation = find(:manage)
        confirm_risk!(automation, automation.working_draft)
        automation.publish!(automation.working_draft)
        render_data(full(automation))
      end

      def revert
        automation = find(:manage)
        old = automation.versions.find_by!(version: params.require(:version).to_i)
        confirm_risk!(automation, old.definition)
        automation.revert!(old.version)
        render_data(full(automation))
      end

      def versions
        automation = find(:manage)
        render_data(automation.versions.includes(:author).map { |v| { version: v.version, author: v.author&.name, created_at: v.created_at, definition: v.definition } })
      end

      # {points: {key_ou_id: valor}, at, trigger, definition?, published?, skip_conditions?}
      # → a execução simulada com o trace (nada é comandado nem avisado).
      def simulate
        automation = find(:manage)
        definition = params.key?(:definition) ? definition_param(automation) : (bool(params[:published]) ? automation.definition : automation.working_draft)
        run = automation.simulate!(points: plain(:points), at: params[:at], trigger: plain(:trigger), definition: definition,
                                   skip_conditions: bool(params[:skip_conditions]))
        render_data(AutomationRunSerializer.new(run).to_h)
      end

      # Executar agora (a versão publicada, sem as condições, como no HA).
      def run
        automation = find(:view)
        raise ActiveRecord::RecordInvalid, automation.tap { |a| a.errors.add(:base, "Publique uma versão antes de executar.") } unless automation.published?

        confirm_risk!(automation, automation.definition)
        run = automation.fire!({ "type" => "manual", "title" => "Executar agora (#{current_user.name})", "user_id" => current_user.id }, skip_conditions: true)
        return render_error(:not_started, "Já há uma execução em andamento (modo #{automation.mode_label.downcase}).", status: :conflict) unless run

        render_data(AutomationRunSerializer.new(run).to_h, status: :accepted)
      end

      def runs
        automation = find(:view)
        scope = automation.runs.recent
        scope = scope.where(dry_run: bool(params[:dry_run])) if params.key?(:dry_run)
        records, meta = paginate(scope)
        render_data(records.map { |r| AutomationRunSerializer.new(r).to_h.except("steps", "state") }, meta: meta)
      end

      # Gera (ou troca) o token do webhook; ele só aparece nesta resposta.
      def webhook
        automation = find(:manage)
        automation.regenerate_webhook_token!
        render_data({ url: "/api/v1/hooks/automations/#{automation.webhook_token}", token: automation.webhook_token })
      end

      private

      def find(action)
        automation = Automation.find(params[:id])
        authorize_site!(automation.site, action)
        automation
      end

      def attrs = params.permit(:name, :description, :mode, :max_runs, :area_id, :enabled).to_h.symbolize_keys

      def apply_definition(automation)
        definition = definition_param(automation)
        return automation.update!(draft: definition) if params[:publish] == false || params[:publish] == "false"

        confirm_risk!(automation, definition)
        automation.publish!(definition)
      end

      # JSON como veio (sem strong params: a DSL valida). Aceita `key` de ponto.
      def definition_param(automation)
        raw = Automations::Dsl.normalize(request.request_parameters["definition"].deep_dup, automation.site)
        errors = automation.errors_in(raw)
        raise ActiveRecord::RecordInvalid, Automation.new.tap { |a| errors.each { |e| a.errors.add(:definition, e) } } if errors.any?

        raw
      end

      def plain(key) = request.request_parameters[key.to_s].is_a?(Hash) ? request.request_parameters[key.to_s] : {}

      # Papel do risco dos pontos comandados; crítico pede confirmação explícita.
      def confirm_risk!(automation, definition)
        risk = automation.max_risk(definition)
        authorize_site!(automation.site, :command, risk: risk)
        return if risk != "critical" || bool(params[:confirm_critical])

        raise ConfirmationRequired, "Esta automação comanda ponto crítico: envie confirm_critical: true."
      end

      def summary(a)
        { id: a.id, site_id: a.site_id, area_id: a.area_id, name: a.name, description: a.description, enabled: a.enabled, mode: a.mode,
          max_runs: a.max_runs, version: a.version, has_draft: a.draft?, webhook: a.webhook_token.present?,
          last_run_at: a.last_run_at, last_status: a.last_status, last_error: a.last_error, updated_at: a.updated_at }
      end

      def full(a) = summary(a).merge(definition: a.definition, draft: a.draft)
    end
  end
end
