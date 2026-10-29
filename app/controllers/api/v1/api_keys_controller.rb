module Api
  module V1
    # Chaves de integração da empresa (só o dono). A chave em claro aparece
    # uma vez, na criação.
    class ApiKeysController < BaseController
      before_action :require_owner!

      def index
        keys = ServiceApiKey.active.joins(:user).where(users: { tenant_id: current_tenant_record.id }).order(created_at: :desc)
        render_data(keys.map { |k| payload(k) })
      end

      # POST { name, scopes: [] }
      def create
        key, plain = ServiceApiKey.issue(current_user, name: params.require(:name), scopes: Array(params[:scopes]))
        render_data(payload(key).merge(token: plain), status: :created)
      rescue ArgumentError
        render_error(:validation_failed, "Escolha ao menos um escopo: #{ServiceApiKey::KNOWN_SCOPES.join(', ')}.", status: :unprocessable_content)
      end

      def destroy
        key = ServiceApiKey.active.joins(:user).where(users: { tenant_id: current_tenant_record.id }).find(params[:id])
        key.update!(revoked_at: Time.current)
        head :no_content
      end

      private

      def payload(k) = { id: k.id, name: k.name, scopes: k.scopes, last_used_at: k.last_used_at, created_at: k.created_at }
    end
  end
end
