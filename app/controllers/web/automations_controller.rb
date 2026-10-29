module Web
  # Automações da DSL (F6). Lista e execuções: qualquer papel no local.
  # Criar, editar (editor de blocos ou JSON avançado), publicar, voltar
  # versão, simular, ligar/desligar e excluir: técnico ou dono. Publicar ou
  # executar automação que comanda ponto sensível/crítico exige o papel do
  # risco (SiteMembership) e, no crítico, a confirmação da tela.
  class AutomationsController < ApplicationController
    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      @automations = @site.automations.includes(:area).ordered.to_a
    end

    def new
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @automation = @site.automations.new
    end

    def create
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @automation = @site.automations.new(automation_params.except(:enabled))
      return render(:new, status: :unprocessable_content) unless @automation.save

      redirect_to edit_automation_path(@automation), notice: "Automação criada. Monte os gatilhos, as condições e as ações e publique."
    end

    def edit
      load_automation(:manage)
      @draft = @automation.working_draft
      @errors = Automations::Dsl.errors(@draft, @site)
      @focus = params[:b]
    end

    # Nome, modo e ligar/desligar (a lista manda só `enabled`).
    def update
      load_automation(:manage)
      return redirect_to(back, alert: @automation.errors.full_messages.to_sentence) unless @automation.update(automation_params)

      notice = automation_params.keys == [ "enabled" ] ? "#{@automation.name} #{@automation.enabled ? 'ligada' : 'desligada'}." : "Automação salva."
      redirect_to back, notice: notice
    end

    def destroy
      load_automation(:manage)
      @automation.destroy!
      redirect_to site_automations_path(@site), notice: "Automação excluída."
    end

    # Operação do editor no rascunho (Automations::Editor).
    def draft
      load_automation(:manage)
      editor = Automations::Editor.new(@automation.working_draft, @site)
      focus = apply(editor)
      @automation.update!(draft: editor.definition)
      redirect_to edit_automation_path(@automation, b: focus, anchor: focus && "b-#{focus.tr('.', '-')}")
    rescue KeyError
      redirect_to edit_automation_path(@automation), alert: "Esse bloco não existe mais no rascunho."
    end

    def publish
      load_automation(:manage)
      definition = @automation.working_draft
      errors = Automations::Dsl.errors(definition, @site)
      return redirect_to(edit_automation_path(@automation), alert: "Corrija antes de publicar: #{errors.first(3).to_sentence}") if errors.any?

      confirm_risk!(definition)
      @automation.publish!(definition)
      redirect_to edit_automation_path(@automation), notice: "Versão #{@automation.version} publicada#{'. Ligue a automação para ela rodar' unless @automation.enabled}."
    end

    def discard
      load_automation(:manage)
      @automation.update!(draft: nil)
      redirect_to edit_automation_path(@automation), notice: "Rascunho descartado."
    end

    def revert
      load_automation(:manage)
      old = @automation.versions.find_by!(version: params[:version].to_i)
      confirm_risk!(old.definition)
      @automation.revert!(old.version)
      redirect_to edit_automation_path(@automation), notice: "Versão #{old.version} publicada de novo como a #{@automation.version}."
    end

    def json
      load_automation(:manage)
      @text = JSON.pretty_generate(Automations::Dsl.with_keys(@automation.working_draft, @site))
    end

    def update_json
      load_automation(:manage)
      @text = params[:definition].to_s
      parsed = Automations::Dsl.normalize(JSON.parse(@text), @site)
      @errors = Automations::Dsl.errors(parsed, @site)
      return render(:json, status: :unprocessable_content) if @errors.any?

      @automation.update!(draft: parsed)
      redirect_to edit_automation_path(@automation), notice: "JSON válido, salvo no rascunho."
    rescue JSON::ParserError => e
      @errors = [ "JSON inválido: #{e.message.truncate(160)}" ]
      render :json, status: :unprocessable_content
    end

    # Formulário da simulação: valores hipotéticos dos pontos citados e a hora.
    def simulate
      load_automation(:manage)
      definition = params[:publicada] == "1" && @automation.published? ? @automation.definition : @automation.working_draft
      @points = @site.points.where(id: Automations::Dsl.point_ids(definition)).includes(:device).ordered.to_a
    end

    def run_simulation
      load_automation(:manage)
      published = params[:publicada] == "1" && @automation.published?
      definition = published ? @automation.definition : @automation.working_draft
      values = params.fetch(:points, {}).permit(*@site.points.pluck(:key)).to_h.compact_blank
      at = params[:at].presence && Time.zone.parse(params[:at].to_s)
      run = @automation.simulate!(points: values, at: at, definition: definition, skip_conditions: params[:skip_conditions] == "1",
                                  trigger: { "title" => "Simulação do #{published ? "versão #{@automation.version}" : 'rascunho'}" })
      redirect_to automation_run_path(run)
    end

    # Executar agora: a versão publicada, sem as condições (como no HA).
    def run
      load_automation(:view)
      return redirect_to(back, alert: "Publique uma versão antes de executar.") unless @automation.published?

      confirm_risk!(@automation.definition)
      run = @automation.fire!({ "type" => "manual", "title" => "Executar agora (#{current_user.name})", "user_id" => current_user.id }, skip_conditions: true)
      return redirect_to(back, alert: "Já há uma execução em andamento (modo #{@automation.mode_label.downcase}).") unless run

      redirect_to automation_run_path(run)
    end

    # Gera (ou troca) o token do webhook; o endereço aparece só agora.
    def webhook
      load_automation(:manage)
      @automation.regenerate_webhook_token!
      flash[:webhook_url] = api_v1_automation_hook_url(token: @automation.webhook_token)
      redirect_to edit_automation_path(@automation, anchor: "webhook")
    end

    private

    # Devolve o bloco para focar depois de salvar.
    def apply(editor)
      target = params[:target].to_s
      case params[:op]
      when "add" then editor.add(target, params[:type].to_s)
      when "update" then editor.update(target, params.fetch(:block, {}).permit(*Automations::Dsl::FORM_FIELDS, days: [], channels: []).to_h)
      when "move" then editor.move(target, params[:dir])
      when "remove" then editor.remove(target) && nil
      else raise KeyError, "op"
      end
    end

    def load_automation(action)
      @automation = Automation.find(params[:id])
      @site = @automation.site
      authorize_site!(@site, action)
    end

    def back = url_from(params[:back].presence) || edit_automation_path(@automation)

    def automation_params
      params.require(:automation).permit(:name, :description, :mode, :max_runs, :area_id, :enabled).tap do |p|
        p[:area_id] = p[:area_id].presence if p.key?(:area_id)
      end
    end

    # Papel do risco dos pontos comandados; crítico pede a confirmação da tela.
    def confirm_risk!(definition)
      risk = @automation.max_risk(definition)
      authorize_site!(@site, :command, risk: risk)
      return if risk != "critical" || params[:confirm_critical] == "1"

      raise SiteMembership::Forbidden, "Esta automação comanda ponto crítico: confirme antes."
    end
  end
end
