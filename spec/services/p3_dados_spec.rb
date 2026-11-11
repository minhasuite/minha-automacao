require "rails_helper"

# P3 da proposta de personalização ("Fora dos painéis"): verificação de
# Saúde, texto dos avisos e voz da casa como dados, sem código. Nada sai para
# a rede nem comanda aparelho real (pontos em aparelho virtual).
RSpec.describe "P3: personalização por dado" do
  let(:tenant) { create(:tenant) }
  let(:owner) { create(:user, tenant: tenant, role: "owner") }
  let(:site) { create(:site, name: "Casa") }
  let(:device) { create(:device, site: site, name: "Lâmpada", driver: "virtual") }
  let!(:luz) { create(:point, site: site, device: device, name: "Luz", key: "sala.luz", value: false, writable: true) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  describe "texto dos avisos (MessageTemplate)" do
    it "renderiza Liquid com o ponto do gatilho, consultas e os atalhos antigos" do
      trigger = MessageTemplate.point_trigger(luz)
      expect(MessageTemplate.render(site, "{ponto} ficou {valor}", trigger: trigger)).to eq("Luz ficou Desligado")
      expect(MessageTemplate.render(site, "{{ trigger.point }} · {{ \"capability=onoff\" | points_where | size }} · {{ \"2 * 3\" | calc }}", trigger: trigger))
        .to eq("Luz · 1 · 6")
      expect(MessageTemplate.preview(site, "{{ points[\"sala.luz\"].text }}")).to eq([ "Desligado", nil ])
      expect(MessageTemplate.preview(site, "{{ \"x\" | nao_existe }}").last).to be_present
      expect(MessageTemplate.syntax_error("{{ abre")).to be_present
      expect(MessageTemplate.syntax_error("ok {{ trigger.point }}")).to be_nil
    end

    it "Aviso (NotifyRule) com Liquid; texto que falha na hora cai no padrão" do
      rule = NotifyRule.create!(point: luz, message: "{{ trigger.point }} em {{ trigger.text }} ({{ site.name }})", channels: [ "in_app" ])
      expect(Notifier).to receive(:deliver!).with([ "in_app" ], hash_including(title: "Luz em Desligado (Casa)"))
      rule.deliver(luz)
      expect(rule.preview).to eq([ "Luz em Desligado (Casa)", nil ])

      rule.update_columns(message: "{{ \"sem_ponto\" | calc }}")
      expect(rule.title_for(luz)).to eq("Luz: Desligado")
      expect(NotifyRule.new(point: luz, message: "{% if %}", channels: [ "in_app" ])).not_to be_valid
      expect(NotifyRule.new(point: luz, channels: [ "in_app" ]).preview).to eq([ "Luz: Desligado", nil ])
    end

    it "Alerta (AlertRule) com texto próprio do aviso e o padrão quando vazio" do
      rule = AlertRule.create!(name: "Luz acesa", point: luz, operator: "eq", value: true, message: "{{ trigger.alert }}: {{ trigger.point }} há {{ trigger.minutes }} min ({{ trigger.severity }})")
      expect(rule.body_for(7)).to eq("Luz acesa: Luz há 7 min (warning)")
      expect(rule.preview).to eq([ "Luz acesa: Luz há 0 min (warning)", nil ])
      rule.update_columns(message: nil)
      expect(rule.body_for(3)).to eq(I18n.t("automations.alerts.push_body", name: "Luz", value: "Desligado", minutes: 3))
      rule.update_columns(message: "{{ \"x\" | calc }}")
      expect(rule.body_for(3)).to include("Luz")
      expect(AlertRule.new(name: "x", point: luz, message: "{{ abre")).not_to be_valid

      alert = rule.alerts.create!(site: site, point: luz, opened_at: Time.current)
      rule.update_columns(message: "Luz ainda {{ trigger.text }}")
      expect(Notifier).to receive(:deliver!).with(anything, hash_including(body: "Luz ainda Desligado"))
      alert.notify_step!({ "channels" => [ "in_app" ] }, 0)
    end
  end

  describe "verificação personalizada da Saúde" do
    let!(:sensor) { create(:point, site: site, device: device, name: "Sensor porta", capability: "contact", quality: "unavailable") }

    it "consulta sozinha: problema quando acha ponto; entra no Health e no aviso diário" do
      check = CustomHealthCheck.create!(site: site, name: "Sem sinal", query: "quality=unavailable", severity: "error")
      res = check.evaluate
      expect(res).to include(problem: true, count: 1)
      expect(res[:detail]).to include("Sensor porta")

      result = Health.run(tenant, only: "custom").first
      expect(result.status).to eq("error")
      expect(result.items.first.title).to eq("Sem sinal (Casa)")
      expect(result.items.first.fix[:url]).to include(check.id)

      expect { Health.alert!(tenant, only: "custom") }.to change(Notification, :count).by(1)
      expect { Health.alert!(tenant, only: "custom") }.not_to change(Notification, :count) # um por dia (dedup_key)
      expect(Notification.last.title).to eq("Personalizadas: Sem sinal (Casa)")
    end

    it "expressão da calculadora com count e texto em Liquid; atenção não avisa" do
      check = CustomHealthCheck.create!(site: site, name: "Muitos", query: "quality=unavailable", expression: "count > 1", severity: "warn",
                                        message: "{{ count }}: {% for p in found %}{{ p.name }}{% endfor %}")
      expect(check.evaluate).to include(problem: false, detail: "1: Sensor porta")
      check.update!(expression: "count_points(\"quality=unavailable\") > 0")
      expect(check.evaluate[:problem]).to be true
      expect(Health.run(tenant, only: "custom").first.status).to eq("warn")
      expect { Health.alert!(tenant, only: "custom") }.not_to change(Notification, :count)

      check.update!(query: nil, message: nil, expression: "hour >= 0")
      expect(check.evaluate).to include(problem: true, detail: I18n.t("custom.health.problem"))
      check.update!(expression: "hour < 0")
      expect(check.evaluate[:detail]).to eq(I18n.t("custom.health.ok"))
    end

    it "valida e mostra o erro sem derrubar as outras" do
      expect(CustomHealthCheck.new(site: site, name: "x")).not_to be_valid
      bad = CustomHealthCheck.new(site: site, name: "x", query: "cor=azul")
      expect(bad).not_to be_valid
      expect(bad.errors[:query].join).to include("cor")
      expect(CustomHealthCheck.new(site: site, name: "x", expression: "1", message: "{% for %}")).not_to be_valid

      broken = CustomHealthCheck.create!(site: site, name: "Quebrada", expression: "ponto_que_nao_existe > 1")
      CustomHealthCheck.create!(site: site, name: "Boa", query: "quality=unavailable")
      items = Health.run(tenant, only: "custom").first.items
      expect(items.map(&:title)).to eq([ "Boa (Casa)", "Quebrada (Casa)" ])
      expect(items.last).to have_attributes(status: "warn")
      expect(items.last.detail).to include("ponto_que_nao_existe")
      expect(broken.preview.last).to be_present

      CustomHealthCheck.delete_all
      expect(Health.run(tenant, only: "custom").first.items.first).to have_attributes(key: "none", status: "ok")
    end

    it "entra no zerar e no exportar" do
      CustomHealthCheck.create!(site: site, name: "Sem sinal", query: "quality=unavailable")
      expect(Accounts::ExportData.call(tenant, owner)[:custom_health_checks].size).to eq(1)
      expect(Accounts::WipeData::MODELS).to include(CustomHealthCheck, AssistCustomIntent, AssistCustomResponse)
      Accounts::WipeData.call(tenant)
      expect(CustomHealthCheck.count).to eq(0)
    end
  end

  describe "voz da casa" do
    def say(text, user: owner, **) = Assist.call(site: site, user: user, text: text, **)

    let(:scene) { site.scenes.create!(name: "Cinema", items: [ { "point_id" => luz.id, "command" => "on" } ]) }

    it "frase da casa aciona a cena, com resposta própria e {slot}, antes das nativas" do
      AssistCustomIntent.create!(site: site, name: "Filme", sentences_text: "(hora|modo) [do] filme\nvamos ver {titulo}", target: "scene:#{scene.id}",
                                 response: "Bom filme: {titulo}")
      expect(say("hora do filme")).to include("intent" => "custom", "text" => "Feito: Cinema.")
      expect(luz.reload.value).to be true
      expect(say("vamos ver Matrix")).to include("text" => "Bom filme: matrix", "slots" => { "titulo" => "matrix" })
      expect(Assist.understand(site, "modo filme").first).to eq(Assist::Intents::Custom)
    end

    it "por idioma, desligada não vale, e script roda pelo comando run" do
      script = create(:point, site: site, device: device, name: "Boa noite", capability: "script", writable: true)
      AssistCustomIntent.create!(site: site, name: "Noite", language: "en", sentences: [ "good night" ], target: "script:#{script.id}")
      off = AssistCustomIntent.create!(site: site, name: "Off", enabled: false, sentences: [ "desligada" ], target: "script:#{script.id}")
      expect(Points::Command).to receive(:call).with(script, "run", nil, source: "voice", user: owner).and_return(Command.new)
      expect(say("good night", language: "en")).to include("intent" => "custom", "text" => "Done: Boa noite.")
      expect(Assist.understand(site, "good night", language: "pt-BR")&.first).not_to eq(Assist::Intents::Custom)
      expect(Assist.understand(site, off.sentences.first)&.first).not_to eq(Assist::Intents::Custom)
    end

    it "crítico nunca: a validação recusa e a execução confere de novo; papel de quem fala vale" do
      luz.update!(risk: "critical")
      ci = AssistCustomIntent.new(site: site, name: "Portão", sentences: [ "abre tudo" ], target: "scene:#{scene.id}")
      expect(ci).not_to be_valid
      expect(ci.errors[:base].join).to include("crítico")
      expect(AssistCustomIntent.targets(site).first.last).to be_empty
      ci.save!(validate: false)
      expect(say("abre tudo")["text"]).to eq("Por voz não posso acionar Cinema.")
      expect(luz.reload.value).to be false

      luz.update!(risk: "sensitive")
      guest = create(:user, tenant: tenant, role: "member")
      create(:site_membership, site: site, user: guest, role: "guest")
      expect(say("abre tudo", user: guest)["text"]).to include("não posso")
    end

    it "na sombra do local nada chega ao aparelho" do
      AssistCustomIntent.create!(site: site, name: "Filme", sentences: [ "filme" ], target: "scene:#{scene.id}")
      site.update!(shadow: true)
      say("filme")
      expect(luz.reload.value).to be false
    end

    it "valida frase, alvo e local" do
      expect(AssistCustomIntent.new(site: site, name: "x", sentences: [ "[abre" ], target: "scene:#{scene.id}")).not_to be_valid
      expect(AssistCustomIntent.new(site: site, name: "x", sentences: [ "ok" ])).not_to be_valid
      expect(AssistCustomIntent.new(site: site, name: "x", sentences: [ "ok" ], target: "script:#{luz.id}")).not_to be_valid
      other = create(:site)
      expect(AssistCustomIntent.new(site: other, name: "x", sentences: [ "ok" ], target: "scene:#{scene.id}")).not_to be_valid
    end

    it "resposta da casa no lugar da padrão, por intenção, idioma e a comum (*)" do
      AssistCustomResponse.create!(site: site, ref: "turn_on.done", text: "Pronto, {names} acesa.")
      expect(say("ligar a luz")["text"]).to eq("Pronto, Luz acesa.")
      AssistCustomResponse.create!(site: site, ref: "*.denied_only", language: "pt-BR", text: "Isso não, %{names}.")
      luz.update!(risk: "critical")
      expect(say("desligar a luz")["text"]).to eq("Isso não, Luz.")
      expect(say("turn off Luz", language: "en")["text"]).to include("can't")
      expect(Assist::Intents::OnOff::On.text(:done, names: "X")).not_to include("Pronto") # fora da conversa: o padrão

      expect(AssistCustomResponse.new(site: site, ref: "nada.done", text: "x")).not_to be_valid
      expect(AssistCustomResponse.new(site: site, ref: "turn_on.done", text: "y")).not_to be_valid # repetida
      expect(AssistCustomResponse.choices.map { |i, k, _| "#{i}.#{k}" }).to include("turn_on.done", "*.denied", "custom.done")
    end

    it "MCP usa as respostas da casa" do
      AssistCustomResponse.create!(site: site, ref: "turn_on.done", text: "Ok {names}")
      out = Assist::Mcp.call(site, owner, "turn_on", { "name" => "luz" })
      expect(out["content"].first["text"]).to eq("Ok Luz")
    end
  end
end
