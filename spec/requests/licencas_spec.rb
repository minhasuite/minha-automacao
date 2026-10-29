require "rails_helper"
require "rake"

# Licenciamento central (licencas/docs/INTEGRACAO.md): informar as assinaturas,
# apagar o dono na exclusão e receber o plano vendido pela web. A central nunca
# está no caminho do usuário.
RSpec.describe "Licenciamento central" do
  let(:user) { create(:user, name: "Ana Souza", email: "ana@loja.com") }
  let(:tenant) { user.tenant }
  let(:base) { "https://lic.test/api/v1" }

  def ligar! = stub_const("ENV", ENV.to_h.merge("LICENCAS_URL" => "https://lic.test/", "LICENCAS_API_KEY" => "chave"))

  def direitos(data, status: 200)
    stub_request(:get, %r{\A#{base}/direitos}).with(headers: { "X-Api-Key" => "chave" })
                                              .to_return(status: status, body: { data: data }.to_json)
  end

  def web_sub(**over)
    { plano: "max", ciclo: "anual", status: "ativa", expira_em: 20.days.from_now.iso8601, renovacao_automatica: true,
      id_externo: "pa-9", email: "ana@loja.com" }.merge(over)
  end

  def play_sub(**attrs)
    tenant.subscriptions.create!({ source: "play", external_id: "tok-1", user: user, plan: "pro", status: "active",
                                   base_plan_id: "mensal", auto_renewing: true, expires_at: 1.month.from_now }.merge(attrs))
  end

  describe "desligado (sem URL/chave)" do
    it "não sai para a rede nem enfileira nada" do
      expect(Licencas::Client.rights([ "a@b.com" ])).to be_nil
      play_sub
      expect { Billing::Entitlement.recompute!(tenant) }.not_to have_enqueued_job(LicencasReportJob)
      LicencasReportJob.perform_now(tenant.id)
      expect(LicencasEnviarTudoJob.perform_now).to eq(0)
      get "/api/v1/billing", headers: auth_headers(user)
      expect(data["plan"]).to eq("pro")
      expect(a_request(:any, /lic\.test/)).not_to have_been_made
    end
  end

  describe "ligado" do
    before { ligar! }

    it "recompute! enfileira o informe; o job manda o mapeamento do contrato" do
      create(:user, tenant: tenant, role: "member")
      play_sub
      tenant.subscriptions.create!(source: "licencas", external_id: "pa-1", plan: "max", status: "active")
      expect { Billing::Entitlement.recompute!(tenant) }.to have_enqueued_job(LicencasReportJob).with(tenant.id)

      bodies = []
      req = stub_request(:post, "#{base}/assinaturas").with(headers: { "X-Api-Key" => "chave" })
                                                       .to_return { |r| bodies << JSON.parse(r.body) && { status: 201, body: "{}" } }
      LicencasReportJob.perform_now(tenant.id)
      expect(req).to have_been_made.once # a `licencas` não volta
      expect(bodies.sole).to include("email" => "ana@loja.com", "nome" => "Ana Souza", "dono_id" => tenant.id, "empresa_nome" => tenant.name,
                                     "usuarios" => 2, "canal" => "play", "id_externo" => "tok-1", "plano" => "pro", "ciclo" => "mensal",
                                     "valor_centavos" => 4990, "status" => "ativa", "renovacao_automatica" => true)
      expect(Time.zone.parse(bodies.sole["expira_em"])).to be_within(2.seconds).of(1.month.from_now)
    end

    it "mapeia status, cortesia manual e quem informa sem comprador" do
      play_sub(user: nil, status: "on_hold", base_plan_id: nil)
      tenant.update!(plan: "max", plan_provider: "manual")
      rows = LicencasReportJob.payloads(tenant)
      expect(rows.first).to include(email: "ana@loja.com", status: "suspensa", ciclo: nil, valor_centavos: nil)
      expect(rows.last).to include(canal: "manual", id_externo: "manual-#{tenant.id}", plano: "max", status: "ativa")
      expect(LicencasReportJob::STATUS.values_at("grace", "canceled", "replaced", "trial")).to eq(%w[carencia cancelada expirada teste])
    end

    it "retroativo licencas:enviar_tudo" do
      play_sub
      req = stub_request(:post, "#{base}/assinaturas").to_return(status: 200, body: "{}")
      Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "licencas:enviar_tudo" }
      expect { Rake::Task["licencas:enviar_tudo"].execute }.to output(/1 empresas/).to_stdout
      expect(req).to have_been_made.once
    end

    it "reenvio diário (LicencasEnviarTudoJob, recurring de produção)" do
      play_sub
      create(:user).tenant.update!(plan: "max", plan_provider: "manual")
      create(:user) # sem assinatura: não vai
      req = stub_request(:post, "#{base}/assinaturas").to_return(status: 200, body: "{}")
      expect(LicencasEnviarTudoJob.perform_now).to eq(2)
      expect(req).to have_been_made.twice
      expect(YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "licencas_enviar_tudo", "class"))
        .to eq("LicencasEnviarTudoJob")
    end

    it "excluir a empresa apaga o dono lá" do
      req = stub_request(:delete, "#{base}/donos/#{tenant.id}").to_return(status: 204)
      expect { delete "/api/v1/me", headers: auth_headers(user) }.to have_enqueued_job(LicencasDeleteJob).with(tenant.id)
      perform_enqueued_jobs(only: LicencasDeleteJob)
      expect(req).to have_been_made
    end

    describe "direitos (venda pela web)" do
      it "concede pelo GET /billing, com os e-mails dos membros" do
        create(:user, tenant: tenant, email: "bruno@loja.com")
        direitos(web_sub)
        get "/api/v1/billing", headers: auth_headers(user)
        expect(a_request(:get, "#{base}/direitos").with(query: { "emails" => %w[ana@loja.com bruno@loja.com] })).to have_been_made
        expect(data).to include("plan" => "max", "provider" => "licencas", "status" => "active", "base_plan" => "anual",
                                "purchased_by_me" => true, "trial_eligible" => true)
        expect(Subscription.sole).to have_attributes(source: "licencas", external_id: "pa-9", user: user, auto_renewing: true)
        expect(tenant.reload.plan_provider).to eq("licencas")
      end

      it "mapeia o status e o melhor direito vence a Play" do
        play_sub
        direitos(web_sub(status: "carencia"))
        Licencas::Sync.call(tenant)
        expect(tenant.reload).to have_attributes(plan: "max", plan_provider: "licencas")
        direitos(web_sub(status: "suspensa", plano: "pro", expira_em: 5.days.from_now.iso8601))
        Licencas::Sync.call(tenant)
        expect(Subscription.find_by(source: "licencas").status).to eq("on_hold")
        expect(tenant.reload).to have_attributes(plan: "pro", plan_provider: "play") # Play vale mais tempo
      end

      it "data null não rebaixa antes da validade; depois expira" do
        direitos(web_sub(expira_em: 2.days.from_now.iso8601))
        Licencas::Sync.call(tenant)
        direitos(nil)
        expect(Licencas::Sync.call(tenant)).to be(false)
        expect(tenant.reload.plan).to eq("max")
        travel_to(3.days.from_now) do
          Billing::Reconcile.call
          expect(Subscription.sole.status).to eq("expired")
          expect(tenant.reload).to have_attributes(plan: "free", plan_provider: nil)
        end
      end

      it "id_externo novo: a antiga vencida expira, a nova vale" do
        tenant.subscriptions.create!(source: "licencas", external_id: "pa-velha", plan: "pro", status: "active", expires_at: 1.day.ago)
        direitos(web_sub)
        Licencas::Sync.call(tenant)
        expect(tenant.subscriptions.pluck(:external_id, :status).sort).to eq([ %w[pa-9 active], %w[pa-velha expired] ])
      end

      it "a pessoa mudou de empresa: o plano vai com ela" do
        other = create(:user)
        sub = other.tenant.subscriptions.create!(source: "licencas", external_id: "pa-9", plan: "max", status: "active",
                                                 expires_at: 20.days.from_now)
        Billing::Entitlement.recompute!(other.tenant)
        direitos(web_sub)
        Licencas::Sync.call(tenant)
        expect(sub.reload.tenant).to eq(tenant)
        expect(other.tenant.reload.plan).to eq("free")
        expect(tenant.reload.plan).to eq("max")
      end

      it "no máximo 1 consulta por minuto por empresa" do
        allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
        req = direitos(nil)
        2.times { get "/api/v1/billing", headers: auth_headers(user) }
        post "/entrar", params: { email: user.email, password: "12345678" }
        get "/configuracoes" # o web consulta pelo mesmo throttle
        expect(response).to have_http_status(:ok)
        expect(req).to have_been_made.once
        travel_to(2.minutes.from_now) { get "/api/v1/billing", headers: auth_headers(user) }
        expect(req).to have_been_made.twice
      end

      it "central fora do ar ou 5xx não quebra nem tira o plano" do
        play_sub
        direitos(web_sub)
        Licencas::Sync.call(tenant)
        allow(Rails.error).to receive(:report)
        stub_request(:get, %r{\A#{base}/direitos}).to_timeout
        get "/api/v1/billing", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
        expect(data["plan"]).to eq("max")
        direitos(nil, status: 503)
        expect(Licencas::Sync.call(tenant)).to be_nil
        stub_request(:post, "#{base}/assinaturas").to_raise(SocketError)
        expect { LicencasReportJob.perform_now(tenant.id) }.not_to raise_error
        expect(Rails.error).to have_received(:report).with(kind_of(StandardError), hash_including(handled: true)).at_least(3).times
        expect(tenant.reload.plan).to eq("max")
      end

      it "erro inesperado no sync do GET /billing também não quebra" do
        allow(Licencas::Sync).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
        get "/api/v1/billing", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "reconciliação pergunta só por quem já tem assinatura de lá" do
        tenant.subscriptions.create!(source: "licencas", external_id: "pa-9", plan: "max", status: "active", expires_at: 20.days.from_now)
        create(:user)
        req = direitos(web_sub(status: "cancelada", renovacao_automatica: false))
        BillingReconcileJob.perform_now
        expect(req).to have_been_made.once
        expect(Subscription.sole).to have_attributes(status: "canceled", auto_renewing: false)
        expect(tenant.reload.plan).to eq("max") # cancelada vale até vencer
      end
    end
  end
end
