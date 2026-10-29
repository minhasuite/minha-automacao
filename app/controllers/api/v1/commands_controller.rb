module Api
  module V1
    # Situação de um comando (POST /points/:id/commands responde 202).
    class CommandsController < BaseController
      def show
        command = Command.find(params[:id])
        authorize_site!(command.site, :view)
        render_data(CommandSerializer.new(command).to_h)
      end
    end
  end
end
