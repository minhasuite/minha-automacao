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
      include SiteAuthorization

      set_current_tenant_through_filter

      # Chave de integração (X-Api-Key): só as ações listadas aqui, cada uma
      # com a permissão que exige (ServiceApiKey::SCOPES). O resto = 403.
      class_attribute :key_actions, default: {}

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

      rescue_from SiteMembership::Forbidden do |e|
        render_error(:forbidden, e.message, status: :forbidden)
      end

      rescue_from Points::Command::Error do |e|
        render_error(e.code, e.message, status: :unprocessable_content)
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
          @service_key = ServiceApiKey.find_by_token(key) or return unauthorized!
          @current_api_user = @service_key.user
          @service_key.touch_usage!
        else
          return unauthorized!
        end
        return unauthorized! if @current_api_user.disabled?

        Current.user = @current_api_user
        Current.theme_key = @current_api_user.dashboard_prefs.to_h["theme"] # ondaB2 (B11)
      end

      def current_user = @current_api_user
      def current_tenant_record = current_user.tenant

      # Chave de integração: a ação precisa estar em `key_actions` e a chave ter
      # a permissão dela. Token do app: acesso conforme o papel da pessoa.
      def check_service_key!
        return if @service_key.nil?
        return if @service_key.scopes.include?(key_actions[action_name.to_sym])

        render_error(:forbidden, "Chave de integração sem acesso a esta operação.", status: :forbidden)
      end

      # Com chave, além do papel, o local precisa estar entre os da chave
      # (fora deles = não encontrado, como sem papel).
      def authorize_site!(site, action, risk: nil)
        raise ActiveRecord::RecordNotFound if @service_key && !@service_key.site_ids.include?(site.id)

        super
      end

      def visible_sites
        sites = Site.visible_to(current_user)
        @service_key ? sites.where(id: @service_key.site_ids) : sites
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
