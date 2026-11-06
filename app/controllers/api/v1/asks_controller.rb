module Api
  module V1
    # POST /sites/:id/ask {question} — card "Perguntar à casa" do app (widget `ask`), o mesmo da web
    # (Ai::Ask: estado dos pontos como contexto, só leitura). → {answer, provider, model}.
    class AsksController < BaseController
      self.key_actions = { create: "read" }

      def create
        site = Site.find(params[:id])
        authorize_site!(site, :view)
        question = params[:question].to_s.strip.truncate(1_000)
        return render_error(:invalid_value, I18n.t("ask.blank"), status: :unprocessable_content) if question.blank?

        response = Ai::Ask.response(site: site, question: question)
        answer = response.data.is_a?(Hash) ? response.data.to_json : response.data.to_s
        render_data({ answer: answer, provider: Ai.provider(response.provider)&.label, model: response.model })
      rescue Ai::Client::Error => e
        render_error(:ai_unavailable, e.message.truncate(200), status: :service_unavailable)
      end
    end
  end
end
