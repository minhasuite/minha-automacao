require "rails_helper"

# Assinatura Grátis/Pro/Max pela Google Play (cópia do minhas-compras). A Play
# é stubada: o que se testa é a regra — o servidor decide o plano, o plano é da
# EMPRESA, o comprovante não anda entre empresas e o plano governa a IA.
RSpec.describe "Assinatura" do
  let(:user) { create(:user, name: "Ana Souza") }
  let(:tenant) { user.tenant }
  let(:headers) { auth_headers(user) }
  let(:member) { create(:user, name: "Bruno Lima", tenant: tenant) }
  let(:token) { "token-#{SecureRandom.hex(8)}" }

  def play_json(state: "SUBSCRIPTION_STATE_ACTIVE", product: "automacao_pro", base_plan: "mensal", offer: nil,
                expiry: 1.month.from_now, account: nil, trial: false, linked: nil, auto_renew: true)
    line = { "productId" => product, "expiryTime" => expiry.utc.iso8601,
             "autoRenewingPlan" => { "autoRenewEnabled" => auto_renew },
             "offerDetails" => { "basePlanId" => base_plan, "offerId" => offer }.compact }
    line["offerPhase"] = trial ? { "freeTrial" => {} } : { "basePrice" => {} }
    { "subscriptionState" => state, "startTime" => 1.day.ago.utc.iso8601, "lineItems" => [ line ],
      "linkedPurchaseToken" => linked,
      "externalAccountIdentifiers" => account ? { "obfuscatedExternalAccountId" => account } : nil }.compact
  end

  def play_returns(**)
    allow(Billing::PlayConfig).to receive(:configured?).and_return(true)
    allow(Billing::GooglePlay).to receive(:subscription).and_return(Billing::GooglePlay.parse(play_json(**)))
  end

  def verify(as: user, purchase_token: token)
    post "/api/v1/billing/google/verify", params: { purchase_token: purchase_token }, headers: auth_headers(as)
  end

  describe "verificação" do
    it "compra válida vira plano da EMPRESA, decidido pelo servidor" do
      play_returns(account: user.id)
      verify
      expect(response).to have_http_status(:ok)
      expect(data).to include("plan" => "pro", "status" => "active", "provider" => "play", "product_id" => "automacao_pro",
                              "base_plan" => "mensal", "purchased_by_me" => true, "trial_eligible" => false)
      expect(data["limits"]).to include("ai_tier" => "light", "ai" => include("ask" => 300))
      expect(tenant.reload).to have_attributes(plan: "pro", plan_provider: "play")

      get "/api/v1/billing", headers: auth_headers(member)
      expect(data).to include("plan" => "pro", "purchased_by_me" => false, "purchaser_name" => "Ana Souza")
    end

    it "reenviar o mesmo comprovante não duplica (o app reenvia no restore)" do
      play_returns
      2.times { verify }
      expect(Subscription.where(source: "play", external_id: token).count).to eq(1)
    end

    it "teste grátis de 14 dias aparece como trial e dá acesso" do
      play_returns(product: "automacao_max", base_plan: "anual", offer: "teste-14-dias", trial: true, expiry: 14.days.from_now)
      verify
      expect(data).to include("plan" => "max", "status" => "trial", "base_plan" => "anual")
      expect(Subscription.sole).to have_attributes(trial: true, offer_id: "teste-14-dias")
    end

    it "comprovante de outra empresa é recusado" do
      play_returns
      verify
      outsider = create(:user)
      verify(as: outsider)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json.dig("error", "code")).to eq("verification_failed")
      expect(outsider.tenant.reload.plan).to eq("free")
    end

    it "outro membro da mesma empresa pode reenviar (restaurar no aparelho dele)" do
      play_returns
      verify
      verify(as: member)
      expect(response).to have_http_status(:ok)
      expect(Subscription.sole.user).to eq(user)
    end

    it "recusa quando a Play diz que a compra é de outro usuário" do
      play_returns(account: SecureRandom.uuid)
      verify
      expect(response).to have_http_status(:unprocessable_content)
      expect(tenant.reload.plan).to eq("free")
    end

    it "produto desconhecido não concede plano" do
      play_returns(product: "produto_que_nao_mapeamos")
      verify
      expect(tenant.reload.plan).to eq("free")
      expect(Subscription.sole.plan).to eq("free")
    end

    it "cancelada continua valendo até o fim; expirada volta ao Grátis" do
      play_returns(state: "SUBSCRIPTION_STATE_CANCELED", auto_renew: false, expiry: 10.days.from_now)
      verify
      expect(data).to include("plan" => "pro", "status" => "canceled", "auto_renewing" => false)

      play_returns(state: "SUBSCRIPTION_STATE_EXPIRED", expiry: 1.day.ago)
      verify
      expect(data).to include("plan" => "free", "status" => "expired")
    end

    it "em carência e em espera ainda dão acesso" do
      %w[SUBSCRIPTION_STATE_IN_GRACE_PERIOD SUBSCRIPTION_STATE_ON_HOLD].each do |state|
        play_returns(state: state)
        verify
        expect(tenant.reload.plan).to eq("pro")
      end
      expect(Subscription.sole.status).to eq("on_hold")
    end

    it "upgrade Pro → Max: o comprovante novo substitui o antigo" do
      play_returns
      verify
      novo = "novo-#{SecureRandom.hex(4)}"
      play_returns(product: "automacao_max", linked: token)
      verify(purchase_token: novo)
      expect(data["plan"]).to eq("max")
      expect(Subscription.find_by(external_id: token).status).to eq("replaced")
    end

    it "melhor direito vence entre dois membros; cortesia do painel não é rebaixada" do
      play_returns
      verify
      play_returns(product: "automacao_max")
      verify(as: member, purchase_token: "outro-token")
      expect(tenant.reload.plan).to eq("max")

      tenant.subscriptions.delete_all
      tenant.update!(plan: "max", plan_provider: "manual", plan_expires_at: nil)
      play_returns
      verify(purchase_token: "terceiro")
      expect(tenant.reload).to have_attributes(plan: "max", plan_provider: "manual")
    end

    it "sem conta de serviço a verificação falha fechada" do
      verify
      expect(response).to have_http_status(:unprocessable_content)
      expect(tenant.reload.plan).to eq("free")
    end

    it "exige autenticação" do
      post "/api/v1/billing/google/verify", params: { purchase_token: token }
      expect(response).to have_http_status(:unauthorized)
    end

    it "consulta a subscriptionsv2 com a conta de serviço" do
      allow(Billing::PlayConfig).to receive(:raw).and_return("{}")
      creds = instance_double(Google::Auth::ServiceAccountCredentials, access_token: "tok", expires_at: 1.hour.from_now)
      allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(creds)
      req = stub_request(:get, "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/com.minhasuite.minhaautomacao/purchases/subscriptionsv2/tokens/abc%2B1")
            .with(headers: { "Authorization" => "Bearer tok" })
            .to_return(status: 200, body: play_json(product: "automacao_max").to_json)
      expect(Billing::GooglePlay.subscription("abc+1")).to include(plan: "max", status: "active", base_plan_id: "mensal")
      expect(req).to have_been_requested

      stub_request(:get, /subscriptionsv2/).to_return(status: 410, body: "gone")
      expect { Billing::GooglePlay.subscription("x") }.to raise_error(Billing::GooglePlay::Error, /410/)
    end
  end

  describe "GET /billing" do
    it "Grátis com catálogo, limites, uso e elegível ao teste" do
      get "/api/v1/billing", headers: headers
      expect(data).to include("plan" => "free", "status" => nil, "trial_eligible" => true)
      expect(data["limits"]).to eq("ai_tier" => nil, "ai" => { "ask" => 0, "daily_summary" => 0 })
      expect(data["usage"]).to eq("ai" => { "ask" => 0, "daily_summary" => 0 })
      pro = data["catalog"].find { |c| c["plan"] == "pro" }
      expect(pro).to include("product_id" => "automacao_pro", "trial_days" => 14)
      expect(pro["prices"]).to eq([ { "base_plan" => "mensal", "period" => "P1M", "price_cents" => 4990 },
                                    { "base_plan" => "anual", "period" => "P1Y", "price_cents" => 49_900, "savings_percent" => 17 } ])
      max = data["catalog"].find { |c| c["plan"] == "max" }
      expect(max["prices"].map { |p| p["price_cents"] }).to eq([ 9990, 99_900 ])
      expect(max["limits"]).to include("ai_tier" => "standard", "ai" => include("ask" => 900))
    end
  end

  describe "RTDN (Pub/Sub push)" do
    def push(note, token_param: "segredo")
      body = { message: { data: Base64.strict_encode64(note.to_json), messageId: "1" }, subscription: "s" }
      post "/webhooks/google_play?token=#{token_param}", params: body, as: :json
    end

    before { stub_const("ENV", ENV.to_h.merge("PLAY_RTDN_TOKEN" => "segredo")) }

    it "token errado = 401; certo reconsulta a Play e aplica" do
      play_returns
      verify
      push({ packageName: "com.minhasuite.minhaautomacao" }, token_param: "x")
      expect(response).to have_http_status(:unauthorized)

      play_returns(state: "SUBSCRIPTION_STATE_EXPIRED", expiry: 1.minute.ago)
      push({ packageName: "com.minhasuite.minhaautomacao", subscriptionNotification: { notificationType: 13, purchaseToken: token } })
      expect(response).to have_http_status(:ok)
      expect(tenant.reload.plan).to eq("free")
    end

    it "renovação estende a validade; estorno (voided) rebaixa" do
      play_returns(expiry: 2.days.from_now)
      verify
      play_returns(expiry: 32.days.from_now)
      push({ packageName: "com.minhasuite.minhaautomacao", subscriptionNotification: { notificationType: 2, purchaseToken: token } })
      expect(Subscription.sole.expires_at).to be > 30.days.from_now

      play_returns(state: "SUBSCRIPTION_STATE_EXPIRED", expiry: Time.current)
      push({ packageName: "com.minhasuite.minhaautomacao", voidedPurchaseNotification: { purchaseToken: token, productType: 1 } })
      expect(tenant.reload.plan).to eq("free")
    end

    it "comprovante nunca verificado: vincula pela conta da compra; sem conta, ignora" do
      play_returns(account: user.id)
      push({ packageName: "com.minhasuite.minhaautomacao", subscriptionNotification: { notificationType: 4, purchaseToken: token } })
      expect(tenant.reload.plan).to eq("pro")

      play_returns
      push({ packageName: "com.minhasuite.minhaautomacao", subscriptionNotification: { notificationType: 4, purchaseToken: "orfao" } })
      expect(response).to have_http_status(:ok)
      expect(Subscription.find_by(external_id: "orfao")).to be_nil
    end

    it "outro pacote, teste do console e erro da Play respondem 200 sem mexer" do
      push({ packageName: "outro.app", subscriptionNotification: { purchaseToken: token } })
      push({ packageName: "com.minhasuite.minhaautomacao", testNotification: { version: "1.0" } })
      expect(response).to have_http_status(:ok)
      allow(Billing::GooglePlay).to receive(:subscription).and_raise(Billing::GooglePlay::Error, "500")
      push({ packageName: "com.minhasuite.minhaautomacao", subscriptionNotification: { purchaseToken: token } })
      expect(response).to have_http_status(:ok)
    end
  end

  describe "reconciliação" do
    it "reconsulta o que venceu sem aviso" do
      play_returns(expiry: 1.hour.from_now)
      verify
      Subscription.sole.update!(expires_at: 1.hour.ago)
      play_returns(expiry: 30.days.from_now) # renovou sem RTDN
      BillingReconcileJob.perform_now
      expect(tenant.reload.plan).to eq("pro")
      expect(Subscription.sole.expires_at).to be > 29.days.from_now
    end
  end

  describe "o plano governa a IA" do
    before { enable_ai! }

    it "Grátis: IA fora do plano (402 Disponível no Pro); Max no tier standard" do
      within(tenant) { expect(Ai::Policy.for(tenant, "ask")).not_to be_allowed }
      post "/api/v1/ai/ask", params: { question: "como economizar energia?" }, headers: headers
      expect(response).to have_http_status(:payment_required)
      expect(json["error"]).to include("code" => "plan_required", "message" => "Disponível no Pro.")
      expect(json.dig("error", "details")).to include("reason" => "not_in_plan", "required_plan" => "pro")

      tenant.update!(plan: "pro")
      within(tenant) { expect(Ai::Policy.for(tenant, "ask")).to have_attributes(tier: :light, limit: 300) }
      tenant.update!(plan: "max")
      within(tenant) { expect(Ai::Policy.for(tenant, "ask")).to have_attributes(tier: :standard, limit: 900) }
      expect(Ai::DailyCap.for(tenant).limit).to eq(240)
    end
  end
end
