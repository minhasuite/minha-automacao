module Api
  module V1
    # Central do integrador: `POST /api/v1/integrador/resumo` com o resumo da instalação (Integrator::Report, JSON
    # até 64 KB) e `Authorization: Bearer <token da instalação>`, sem login. Grava, avalia os avisos na hora e
    # responde a versão que a central libera (freio). 404 fora da central (sem INTEGRATOR_HUB=1) ou token errado.
    class IntegratorReportsController < ActionController::API
      MAX_BYTES = 65_536

      rate_limit to: 30, within: 1.minute, by: -> { request.authorization.to_s.last(16) }

      def create
        return not_found unless Integrator.hub?
        return render(json: { error: { code: "payload_too_large" } }, status: :content_too_large) if request.content_length.to_i > MAX_BYTES

        installation = Installation.find_by_token(request.authorization.to_s.delete_prefix("Bearer ").strip) or return not_found
        payload = request.request_parameters.except("controller", "action", "integrator_report")
        ActsAsTenant.with_tenant(installation.tenant) do
          installation.receive!(payload)
          Integrator::Watch.evaluate!(installation)
        end
        render json: { max_version: installation.max_version, status: installation.status }
      end

      private

      def not_found = render(json: { error: { code: "not_found" } }, status: :not_found)
    end
  end
end
