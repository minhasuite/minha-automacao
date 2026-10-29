module Api
  module V1
    # Base da API v1. Contrato da suíte:
    #   sucesso → { data, meta? }      erro → { error: { code, message, details? } }
    # Autentica (Bearer do app ou X-Api-Key de integração) ANTES de fixar a
    # empresa: tokens não são tenant-scoped, e require_tenant exige a empresa
    # em toda query de dado dela.
    class BaseController < ActionController::API
      include Pagy::Backend
      include MeuLogInstrumented

      set_current_tenant_through_filter

      class_attribute :service_scope, default: nil
      class_attribute :service_write_scope, default: nil

      before_action :authenticate_request!
      before_action :check_service_key!
      before_action :set_tenant

      rescue_from ActiveRecord::RecordNotFound do
        render_error(:not_found, "Recurso não encontrado.", status: :not_found)
      end

      rescue_from ActiveRecord::RecordInvalid do |e|
        render_error(:validation_failed, e.record.errors.full_messages.to_sentence.presence || "Dados inválidos.",
                     status: :unprocessable_content, details: e.record.errors.to_hash(true))
      end

      rescue_from ActionController::ParameterMissing do |e|
        render_error(:parameter_missing, "Parâmetro obrigatório ausente: #{e.param}.", status: :bad_request)
      end

      rescue_from Ai::QuotaExceeded do |e|
        details = { feature: e.feature, reason: e.not_in_plan? ? "not_in_plan" : "quota", required_plan: "pro" }
        render_error(:plan_required, e.user_message, status: :payment_required, details: details)
      end

      rescue_from ActsAsTenant::Errors::NoTenantSet do |e|
        Rails.logger.error("[api] NoTenantSet: #{e.message}")
        render_error(:internal_error, "Erro interno.", status: :internal_server_error)
      end

      private

      def meulog_uso_por_requisicao? = true

      def authenticate_request!
        if (bearer = request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]).present?
          token = ApiToken.find_by_access(bearer) or return unauthorized!
          @current_api_user = token.user
          @current_api_token = token
          token.touch_usage!
        elsif (key = request.headers["X-Api-Key"].presence)
          service_key = ServiceApiKey.find_by_token(key) or return unauthorized!
          @current_api_user = service_key.user
          @current_scopes = service_key.scopes
          service_key.touch_usage!
        else
          return unauthorized!
        end
        Current.user = @current_api_user
      end

      def current_user = @current_api_user
      def current_tenant_record = current_user.tenant

      # Chave de serviço (X-Api-Key): GET em controller com `service_scope`, ou
      # escrita em controller com `service_write_scope`, cobertos pela chave.
      # Token do app: acesso
      # total à própria empresa.
      def check_service_key!
        return if @current_scopes.nil?
        return if request.get? && service_scope && @current_scopes.include?(service_scope)
        return if !request.get? && service_write_scope && @current_scopes.include?(service_write_scope)

        render_error(:forbidden, "Chave de integração sem acesso a esta operação.", status: :forbidden)
      end

      def set_tenant = set_current_tenant(current_user.tenant)

      def unauthorized! = render_error(:unauthorized, "Credenciais ausentes ou inválidas.", status: :unauthorized)

      def render_data(payload, status: :ok, meta: nil)
        body = { data: payload }
        body[:meta] = meta if meta
        render json: body, status: status
      end

      def render_error(code, message, status:, details: nil)
        error = { code: code, message: message }
        error[:details] = details if details.present?
        render json: { error: error }, status: status
      end

      # Pagy com meta no corpo: { page, per_page, count, pages, next, prev }.
      def paginate(scope)
        pagy, records = pagy(scope)
        [ records, { page: pagy.page, per_page: pagy.limit, count: pagy.count, pages: pagy.pages, next: pagy.next, prev: pagy.prev } ]
      end

      def bool(value) = ActiveModel::Type::Boolean.new.cast(value)

      def require_owner!
        render_error(:forbidden, "Só o dono da empresa pode fazer isso.", status: :forbidden) unless current_user.owner?
      end

      def require_admin!
        render_error(:forbidden, "Só administrador ou dono pode fazer isso.", status: :forbidden) unless current_user.admin?
      end
    end
  end
end
