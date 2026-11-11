module Api
  module V1
    # Respostas personalizadas da voz (P3, `AssistCustomResponse`). `ref` =
    # "intenção.chave" (ou "*.chave" para os textos comuns); a lista traz em
    # `meta.choices` o que dá para trocar, com o texto padrão no idioma.
    class AssistCustomResponsesController < AutomationController
      self.model = AssistCustomResponse
      self.fields = %i[ref language text]

      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        choices = AssistCustomResponse.choices.map { |i, k, t| { "ref" => "#{i}.#{k}", "default" => t } }
        render_data(model.where(site_id: site.id).order(:created_at).map { |r| serialize(r) }, meta: { choices: choices })
      end

      private

      def serialize(record) = super.merge("ref" => record.ref)
    end
  end
end
