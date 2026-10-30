module Web
  # Automações da DSL (F6) e scripts (F8f, `kind: "script"`, mesmas telas).
  # Lista e execuções: qualquer papel no local. Criar, editar (editor de
  # blocos ou JSON avançado), publicar, voltar versão, simular, ligar/desligar,
  # campos do script, ações em massa e excluir: técnico ou dono. Publicar ou
  # executar o que comanda ponto sensível/crítico exige o papel do risco
  # (SiteMembership) e, no crítico, a confirmação da tela.
  class AutomationsController < ApplicationController
    STATES = { "ativas" => true, "desativadas" => false }.freeze

    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      @total = @site.automations.count
      @automations = filtered(@site.automations.includes(:area, :tags).ordered).to_a
      @labels = Tag.joins(:taggings).where(taggings: { taggable_type: "Automation", taggable_id: @site.automations.select(:id) }).distinct.order(:name).pluck(:name)
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
      @errors = @automation.errors_in(@draft)
      @focus = params[:b]
    end

    # Nome, modo, rótulos e ligar/desligar (a lista manda só `enabled`).
    def update
      load_automation(:manage)
      return redirect_to(back, alert: @automation.errors.full_messages.to_sentence) unless @automation.update(automation_params)

      notice = automation_params.keys == [ "enabled" ] ? "#{@automation.name} #{@automation.enabled ? 'ligada' : 'desligada'}." : "#{@automation.kind_label} salva."
      redirect_to back, notice: notice
    end

    def destroy
      load_automation(:manage)
      @automation.destroy!
      redirect_to list_path, notice: "#{@automation.kind_label} excluída."
    end

    # Ações em massa da lista: ligar, desligar ou excluir as marcadas.
    def bulk
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      list = Automation.where(site_id: @site.id, id: Array(params[:ids]).compact_blank).to_a
      back = url_from(params[:back].presence) || site_automations_path(@site)
      return redirect_to(back, alert: "Marque pelo menos uma.") if list.empty?

      redirect_to back, notice: bulk_apply(list)
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
      errors = @automation.errors_in(definition)
      return redirect_to(edit_automation_path(@automation), alert: "Corrija antes de publicar: #{errors.first(3).to_sentence}") if errors.any?

      confirm_risk!(@automation.max_risk(definition))
      @automation.publish!(definition)
      later = @automation.script? || @automation.enabled ? "" : ". Ligue a automação para ela rodar"
      redirect_to edit_automation_path(@automation), notice: "Versão #{@automation.version} publicada#{later}."
    end

    def discard
      load_automation(:manage)
      @automation.update!(draft: nil)
      redirect_to edit_automation_path(@automation), notice: "Rascunho descartado."
    end

    def revert
      load_automation(:manage)
      old = @automation.versions.find_by!(version: params[:version].to_i)
      confirm_risk!(@automation.max_risk(old.definition))
      @automation.revert!(old.version)
      redirect_to edit_automation_path(@automation), notice: "Versão #{old.version} publicada de novo como a #{@automation.version}."
    end

    # O blueprint mudou: refaz o rascunho com as mesmas entradas.
    def rebuild
      load_automation(:manage)
      errors = @automation.blueprint ? @automation.blueprint.rebuild_draft!(@automation) : [ "Sem blueprint." ]
      return redirect_to(edit_automation_path(@automation), alert: errors.to_sentence) if errors.any?

      redirect_to edit_automation_path(@automation), notice: "Rascunho refeito pelo blueprint (versão #{@automation.blueprint.version}). Revise e publique."
    end

    # Campos do script: adicionar, alterar ou remover (na hora, fora do rascunho).
    def fields
      load_automation(:manage)
      list = @automation.fields.deep_dup
      i = params[:index].to_i
      case params[:op]
      when "add" then list << field_params
      when "update" then list[i] = field_params if list[i]
      when "remove" then list.delete_at(i)
      end
      list = with_defaults(list)
      saved = @automation.update(fields: list)
      redirect_to edit_automation_path(@automation, anchor: "campos"), **(saved ? { notice: "Campos salvos." } : { alert: @automation.errors.full_messages.to_sentence })
    rescue ArgumentError => e
      redirect_to edit_automation_path(@automation, anchor: "campos"), alert: "Padrão inválido: #{e.message}"
    end

    def json
      load_automation(:manage)
      @text = JSON.pretty_generate(Automations::Dsl.with_keys(@automation.working_draft, @site))
    end

    def update_json
      load_automation(:manage)
      @text = params[:definition].to_s
      parsed = Automations::Dsl.normalize(JSON.parse(@text), @site)
      @errors = @automation.errors_in(parsed)
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

    # Script com campos: formulário antes de executar.
    def run_form
      load_automation(:view)
      redirect_to edit_automation_path(@automation) unless @automation.script?
    end

    # Executar agora: a versão publicada, sem as condições (como no HA); no
    # script, com os campos do formulário.
    def run
      load_automation(:view)
      return redirect_to(back, alert: "Publique uma versão antes de executar.") unless @automation.published?
      return run_script if @automation.script?

      confirm_risk!(@automation.max_risk(@automation.definition))
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

    def filtered(scope)
      scope = scope.where("automations.name ILIKE ?", "%#{Automation.sanitize_sql_like(params[:q].to_s.strip)}%") if params[:q].present?
      scope = scope.where(enabled: STATES[params[:estado]]) if STATES.key?(params[:estado])
      scope = scope.where(area_id: params[:area]) if params[:area].present?
      scope = scope.where(id: Tagging.joins(:tag).where(taggable_type: "Automation", tags: { name: params[:rotulo] }).select(:taggable_id)) if params[:rotulo].present?
      scope
    end

    def bulk_apply(list)
      case params[:op]
      when "enable"
        ok = list.select { |a| a.published? && !a.script? }
        ok.each { |a| a.update!(enabled: true) }
        "#{count(ok.size)} ligada#{'s' if ok.size != 1}#{' (só as publicadas)' if ok.size < list.size}."
      when "disable"
        list.each { |a| a.update!(enabled: false) }
        "#{count(list.size)} desligada#{'s' if list.size != 1}."
      when "delete"
        list.each(&:destroy!)
        "#{count(list.size)} excluída#{'s' if list.size != 1}."
      else "Nada feito."
      end
    end

    def count(n) = helpers.count_label(n, "automação", "automações")

    def run_script
      values = @automation.field_values(params.fetch(:fields, {}).permit(*@automation.fields.pluck("name")).to_h)
      confirm_risk!(@automation.run_risk(values))
      run = @automation.run_script!(values, title: "Executar (#{current_user.name})", user: current_user)
      return redirect_to(back, alert: "Já está rodando (modo #{@automation.mode_label.downcase}).") unless run

      redirect_to automation_run_path(run)
    rescue ArgumentError => e
      redirect_to run_automation_path(@automation), alert: e.message.upcase_first
    end

    def field_params
      p = params.require(:field).permit(:name, :label, :type, :default, :required, :options)
      fd = { "name" => p[:name].to_s.strip.downcase, "label" => p[:label].to_s.squish.presence || p[:name].to_s.humanize,
             "type" => p[:type].to_s, "required" => p[:required] == "1", "default" => p[:default].to_s.strip.presence }
      fd["options"] = p[:options].to_s.split(",").map(&:strip).compact_blank if fd["type"] == "select"
      fd.compact
    end

    # Padrão em texto → tipo do campo (ArgumentError se não converte).
    def with_defaults(list)
      probe = Automation.new(site: @site, kind: "script", fields: list)
      list.map { |fd| fd["default"].is_a?(String) ? fd.merge("default" => probe.cast_fields(fd["name"] => fd["default"])[fd["name"]]) : fd }
    end

    # Devolve o bloco para focar depois de salvar.
    def apply(editor)
      target = params[:target].to_s
      case params[:op]
      when "add" then editor.add(target, params[:type].to_s)
      when "update" then editor.update(target, params.fetch(:block, {}).permit(*Automations::Dsl.form_fields, days: [], channels: [], fields: {}).to_h)
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

    def list_path = @automation.script? ? site_scripts_path(@site) : site_automations_path(@site)
    def back = url_from(params[:back].presence) || edit_automation_path(@automation)

    def automation_params
      params.require(:automation).permit(:name, :description, :mode, :max_runs, :area_id, :enabled, :icon, :label_list).tap do |p|
        p[:area_id] = p[:area_id].presence if p.key?(:area_id)
      end
    end

    # Papel do risco dos pontos comandados; crítico pede a confirmação da tela.
    def confirm_risk!(risk)
      authorize_site!(@site, :command, risk: risk)
      return if risk != "critical" || params[:confirm_critical] == "1"

      raise SiteMembership::Forbidden, "Esta #{@automation.kind_label.downcase} comanda ponto crítico: confirme antes."
    end
  end
end
