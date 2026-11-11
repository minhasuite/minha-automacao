module Api
  module V1
    # Verificações personalizadas da Saúde (P3), as mesmas de Configurações →
    # Saúde → Verificações personalizadas. Só administradores.
    #   GET/POST /health_checks, GET/PATCH/DELETE /health_checks/:id
    #   POST /health_checks/preview {site_id, query, expression, severity, message} → {problem, status, count, detail}
    class CustomHealthChecksController < BaseController
      FIELDS = %i[site_id name query expression severity message enabled].freeze

      before_action :require_admin!

      def index = render_data(CustomHealthCheck.includes(:site).order(:name).map { |c| serialize(c) })
      def show = render_data(serialize(CustomHealthCheck.find(params[:id]), result: true))

      def create
        render_data(serialize(CustomHealthCheck.create!(attrs)), status: :created)
      end

      def update
        check = CustomHealthCheck.find(params[:id])
        check.update!(attrs)
        render_data(serialize(check))
      end

      def destroy
        CustomHealthCheck.find(params[:id]).destroy!
        head :no_content
      end

      def preview
        check = CustomHealthCheck.new(attrs.reverse_merge(name: "preview"))
        return render_error(:invalid, check.errors.full_messages.to_sentence, status: :unprocessable_content) unless check.valid?

        res, error = check.preview
        return render_error(:invalid_check, error, status: :unprocessable_content) if error

        render_data(res.merge(status: res[:problem] ? check.severity : "ok"))
      end

      private

      def attrs
        p = params.permit(*FIELDS).to_h.symbolize_keys
        p[:site_id] = Site.find(p[:site_id]).id if p[:site_id].present?
        p
      end

      def serialize(check, result: false)
        json = check.as_json(except: "tenant_id")
        json["result"] = Health::Checks::Custom.item_for(check).then { |i| { "status" => i.status, "detail" => i.detail } } if result
        json
      end
    end
  end
end
