module Api
  module V1
    class AiController < BaseController
      ASK_SYSTEM = "Você é o assistente do Minha Automação. Responda em português do Brasil, curto e direto.".freeze
      ASK_SCHEMA = { type: "object", properties: { answer: { type: "string" } }, required: %w[answer] }.freeze

      # GET /ai/quota — o app decide o que oferecer antes de gastar.
      def quota
        tenant = current_tenant_record
        cap = Ai::DailyCap.for(tenant)
        render_data({
          enabled: Ai::Client.enabled?,
          plan: tenant.plan,
          features: AiPlanFeature::FEATURES.index_with { |f| Ai::Policy.for(tenant, f).as_json },
          daily: { limit: cap.limit, used: cap.used, remaining: cap.remaining }
        })
      end

      # POST /ai/ask { question } (administrador). Placeholder até o domínio de
      # automação chegar: pergunta livre, sem dados da empresa.
      def ask
        return require_admin! unless current_user.admin?

        policy = Ai::Policy.for(current_tenant_record, :ask)
        policy.check!
        response = Ai::Client.new(tier: policy.tier).complete(system: ASK_SYSTEM, user: params.require(:question).to_s.truncate(2000),
                                                              schema: ASK_SCHEMA, max_tokens: 1_000)
        policy.record!(response)
        render_data({ answer: response.data[:answer].to_s })
      rescue Ai::Client::Error => e
        render_error(:ai_unavailable, "A IA não respondeu agora: #{e.message.truncate(120)}", status: :service_unavailable)
      end
    end
  end
end
