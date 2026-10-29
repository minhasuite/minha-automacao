module Web
  # Cenas: cadastro (técnico ou dono) e acionar (papel conforme o ponto de
  # maior risco da cena).
  class ScenesController < AutomationController
    self.model = Scene
    self.label = "Cena"

    def activate
      @record = Scene.find(params[:id])
      @site = @record.site
      authorize_site!(@site, :command, risk: @record.risk)
      _commands, failures = @record.activate!(source: "web")
      redirect_to back_path, **(failures.any? ? { alert: failures.to_sentence } : { notice: "Cena #{@record.name} acionada." })
    end

    private

    def permitted = [ :name, :icon, { items: %i[point_id command value] } ]
  end
end
