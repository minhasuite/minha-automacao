module Api
  module V1
    # POST /sites/:id/talk {targets: "all" | [ids], text? | audio (arquivo)}
    # — "Falar na Alexa" do app (widget `announce`), o mesmo da web (Alexa::Talk).
    class TalksController < BaseController
      self.key_actions = { create: "command" }

      def create
        site = Site.find(params[:id])
        authorize_site!(site, :command)
        commands = Alexa::Talk.call(site, targets: params[:targets], text: params[:text], audio: params[:audio], source: "api",
                                          allow: ->(p) { authorize_site!(site, :command, risk: p.risk) })
        render_data(commands.map { |c| CommandSerializer.new(c).to_h }, status: :accepted)
      rescue Alexa::Talk::Error => e
        render_error(:invalid_value, e.message, status: :unprocessable_content)
      end
    end
  end
end
