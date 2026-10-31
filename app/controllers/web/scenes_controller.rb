module Web
  # Cenas (F4, revistas na F8f): lista, cadastro (técnico ou dono) e acionar
  # (papel conforme o ponto de maior risco da cena). "Capturar estado agora"
  # lê o valor atual dos pontos escolhidos e vira linhas da cena, sem salvar e
  # sem comandar nada. O modo ao vivo (desligado por padrão) aciona a cena
  # depois de salvar, com o papel do risco.
  class ScenesController < AutomationController
    self.model = Scene
    self.label = "Cena"

    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      scope = @site.scenes.order(:name)
      scope = scope.where("scenes.name ILIKE ?", "%#{Scene.sanitize_sql_like(params[:q].to_s.strip)}%") if params[:q].present?
      @total = @site.scenes.count
      @scenes = scope.to_a
    end

    def create
      load_site
      @record = model.new(record_params.merge(site: @site))
      return capture if params[:capture]
      return render("web/automation/edit", status: :unprocessable_content) unless @record.save

      saved
    end

    def update
      load_record
      @record.assign_attributes(record_params)
      return capture if params[:capture]
      return render("web/automation/edit", status: :unprocessable_content) unless @record.save

      saved
    end

    def activate
      @record = Scene.find(params[:id])
      @site = @record.site
      authorize_site!(@site, :command, risk: @record.risk)
      _commands, failures = @record.activate!(source: "web")
      redirect_to back_path, **(failures.any? ? { alert: failures.to_sentence } : { notice: "Cena #{@record.name} acionada." })
    end

    private

    def capture
      ids = Array(params[:capture_ids]).compact_blank
      captured = @site.points.where(id: ids, writable: true).filter_map { |p| Scene.capture(p) }
      @record.items = @record.items.reject { |i| captured.any? { |c| c["point_id"] == i["point_id"] } } + captured
      flash.now[:notice] = captured.empty? ? "Nenhum ponto com valor para capturar." : "Estado de #{helpers.count_label(captured.size, 'ponto', 'pontos')} capturado. Ajuste e salve."
      render "web/automation/edit"
    end

    def saved
      return redirect_to(back_path, notice: "Cena salva.") unless params[:live] == "1"

      authorize_site!(@site, :command, risk: @record.risk)
      _commands, failures = @record.activate!(source: "web")
      redirect_to edit_scene_path(@record, back: params[:back].presence),
                  **(failures.any? ? { alert: "Salva; ao vivo: #{failures.to_sentence}" } : { notice: "Cena salva e aplicada ao vivo." })
    end

    def back_path = url_from(params[:back].presence) || site_scenes_path(@site)
    def permitted = [ :name, :icon, :shadow, { items: %i[point_id command value] } ]
  end
end
