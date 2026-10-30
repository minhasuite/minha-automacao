module Api
  module V1
    # Cenas. Acionar: papel conforme o ponto de maior risco da cena; 202 com
    # os comandos criados e os erros de cada ponto (os outros seguem).
    class ScenesController < AutomationController
      self.model = Scene
      self.fields = [ :name, :icon, { items: %i[point_id command value] } ]
      # Chave de integração (F8f): listar e ver com "read", acionar com "command".
      self.key_actions = { index: "read", show: "read", activate: "command" }

      def activate
        scene = Scene.find(params[:id])
        authorize_site!(scene.site, :command, risk: scene.risk)
        commands, failures = scene.activate!(source: "api")
        render_data({ commands: CommandSerializer.new(commands).to_h, errors: failures }, status: :accepted)
      end
    end
  end
end
