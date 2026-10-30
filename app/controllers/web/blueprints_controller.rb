module Web
  # Blueprints (F8f): os prontos (config/blueprints), importar do Home
  # Assistant (YAML ou URL), ver, editar o JSON (propaga para as automações
  # criadas dele) e "criar automação a partir dele". Ver: qualquer papel;
  # o resto: técnico ou dono. Criar a automação publica com o papel do risco
  # dos pontos escolhidos; ponto crítico sem confirmação fica no rascunho.
  class BlueprintsController < ApplicationController
    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      Blueprints.sync_builtin!(@site)
      @blueprints = @site.blueprints.ordered.to_a
      @counts = Automation.where(blueprint_id: @blueprints.map(&:id)).group(:blueprint_id).count
    end

    def new
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
    end

    # Importar do HA: URL (GitHub, gist, comunidade) ou YAML colado.
    def create
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      url = params[:url].to_s.strip.presence
      text = url ? Blueprints::HaImport.fetch(url) : params[:yaml].to_s
      list = Blueprints::HaImport.import(text, source_url: url)
      return import_many(list) if list.size > 1

      attrs = list.first
      @unsupported = attrs["unsupported"]
      return import_error("Nada que a DSL daqui rode: #{empty_parts(attrs).to_sentence}.") if empty_parts(attrs).any?

      blueprint = @site.blueprints.create!(attrs)
      notice = @unsupported.any? ? "Importado com #{helpers.count_label(@unsupported.size, 'parte', 'partes')} não suportada#{'s' if @unsupported.size != 1}: confira abaixo." : "Importado."
      redirect_to blueprint_path(blueprint), notice: notice
    rescue Blueprints::HaImport::Error, ActiveRecord::RecordInvalid => e
      import_error(e.message)
    end

    def show
      load_blueprint(:view)
      @automations = @blueprint.automations.ordered.to_a
    end

    # JSON avançado (nome, descrição, modo, inputs, definition). Os prontos não se editam.
    def update
      load_blueprint(:manage)
      return redirect_to(blueprint_path(@blueprint), alert: "Blueprint pronto não se edita.") if @blueprint.builtin?

      data = JSON.parse(params[:json].to_s)
      raise JSON::ParserError, "precisa ser um objeto" unless data.is_a?(Hash)

      @blueprint.assign_attributes(data.slice("name", "description", "mode", "inputs", "definition"))
      changed = @blueprint.will_save_change_to_definition? || @blueprint.will_save_change_to_inputs? || @blueprint.will_save_change_to_mode?
      @blueprint.save!
      linked = @blueprint.automations.count
      redirect_to blueprint_path(@blueprint), notice: changed && linked.positive? ? "Versão #{@blueprint.version}: rascunho refeito em #{helpers.count_label(linked, 'automação', 'automações')}." : "Blueprint salvo."
    rescue JSON::ParserError, ActiveRecord::RecordInvalid => e
      redirect_to blueprint_path(@blueprint), alert: "Não salvou: #{e.message.truncate(160)}"
    end

    def destroy
      load_blueprint(:manage)
      return redirect_to(blueprint_path(@blueprint), alert: "Blueprint pronto não se exclui.") if @blueprint.builtin?

      @blueprint.destroy!
      redirect_to site_blueprints_path(@site), notice: "Blueprint excluído. As automações criadas dele continuam."
    end

    # Formulário gerado pelas entradas.
    def use
      load_blueprint(:manage)
      @values = {}
    end

    def instantiate
      load_blueprint(:manage)
      @values = params.fetch(:inputs, {}).permit(*@blueprint.inputs.pluck("key")).to_h
      definition, _clean, errors = @blueprint.instantiate(@values)
      return use_error(errors) if errors.any?

      risk = Automations::Dsl.max_risk(definition, @site)
      authorize_site!(@site, :command, risk: risk)
      # Ponto crítico: fica no rascunho; publicar no editor pede a confirmação.
      a = @blueprint.create_automation!(name: params[:name], values: @values, area_id: params[:area_id], publish: risk != "critical")
      redirect_to edit_automation_path(a), notice: created_notice(a)
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      use_error([ e.message ])
    end

    private

    def load_blueprint(action)
      @blueprint = Blueprint.find(params[:id])
      @site = @blueprint.site
      authorize_site!(@site, action)
    end

    def empty_parts(attrs)
      d = attrs["definition"]
      [ ("nenhum gatilho" if attrs["domain"] == "automation" && d["triggers"].blank?), ("nenhuma ação" if d["actions"].blank?) ].compact
    end

    # Várias automações/scripts do HA (Lote 4, G32): um blueprint por item; os
    # que não têm nada que rode ficam de fora e entram na contagem.
    def import_many(list)
      ok, empty = list.partition { |a| empty_parts(a).empty? }
      Blueprint.transaction { ok.each { |a| @site.blueprints.create!(a) } }
      partial = ok.count { |a| a["unsupported"].any? }
      parts = [ "#{helpers.count_label(ok.size, 'importado', 'importados')} como blueprint",
                ("#{partial} com partes não suportadas" if partial.positive?),
                ("#{empty.size} sem nada que rode aqui: #{empty.map { |a| a['name'] }.first(5).to_sentence}" if empty.any?) ].compact
      redirect_to site_blueprints_path(@site), notice: "#{parts.join('; ')}. Abra cada um e use \"Criar automação\" para escolher os pontos."
    end

    def import_error(message)
      @error = message
      render :new, status: :unprocessable_content
    end

    def use_error(errors)
      @errors = errors
      render :use, status: :unprocessable_content
    end

    def created_notice(a)
      noun = a.kind_label
      return "#{noun} criada no rascunho: confira e publique (o editor mostra o que falta)." unless a.published?

      a.script? ? "#{noun} criado e publicado." : "#{noun} criada e publicada, ainda desligada: confira e ligue."
    end
  end
end
