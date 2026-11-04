require "rails_helper"

# Lote 2 da paridade com o HA: IA da instalação (provedores plugáveis, ação
# "Pedir à IA", "Gerar dados por IA", limite e custo) e conjuntos de dados
# (ação "Registrar dados", "Consultar dados", helper Consulta).
RSpec.describe "Lote 2: IA e dados nas automações" do
  let(:tenant) { create(:tenant) }
  let(:owner) { create(:user, tenant: tenant, role: "owner", name: "Dona") }
  let(:site) { within(tenant) { create(:site, name: "Local") } }
  let(:area) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Virtual", driver: "virtual") } }
  let(:temp) { within(tenant) { create(:point, device: device, site: site, area: area, key: "sala.temp", name: "Temperatura", capability: "measure", data_type: "decimal", value: 24.5) } }
  let(:lamp) { within(tenant) { create(:point, device: device, site: site, key: "sala.luz", name: "Luz", writable: true, value: true) } }
  let(:dataset) { within(tenant) { Dataset.create!(site: site, name: "Aberturas", fields_text: "porta: texto\nminutos: número\nok: sim/não") } }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def build(definition)
    a = Automation.create!(site: site, name: "Teste Lote2 #{SecureRandom.hex(3)}", kind: "automation", mode: "single")
    a.publish!(definition)
    a.update!(enabled: true)
    a
  end

  def fire(actions) = build({ "triggers" => [ { "type" => "manual" } ], "actions" => actions }).fire!({ "type" => "manual" })

  # Provedor falso: devolve o pedido (texto) ou um objeto (estruturado).
  def fake_provider!(capabilities: %i[text structured])
    seen = []
    klass = Class.new(Ai::Providers::Base) do
      describe key: "eco", label: "Eco de teste", default_model: "eco-1", capabilities: capabilities, key_required: false
      define_method(:complete) do |model:, system:, user:, schema:, **opts|
        seen << { model: model, system: system, user: user, schema: schema, **opts }
        data = schema ? { "resumo" => "tudo certo", "anomalia" => false } : "eco: #{user.is_a?(String) ? user : user.last[:text]}"
        Ai::Providers::Base::Result.new(data: data, usage: { input: 10, output: 5 })
      end
    end
    stub_const("Ai::Providers::Eco", klass)
    stub_const("Ai::PROVIDERS", Ai::PROVIDERS + %w[Eco])
    AiAccount.create!(provider: "eco")
    seen
  end

  describe "plugins: o núcleo não muda" do
    it "um provedor de IA falso registrado funciona na ação e no Ai::Request" do
      seen = fake_provider!
      expect(Ai.choices).to include("eco" => "Eco de teste")
      run = fire([ { "type" => "ai_task", "prompt" => "Oi {{ site.name }}", "provider" => "eco", "response_variable" => "r" },
                   { "type" => "set", "var" => "t", "value" => "{{ r.data }}" } ])
      expect(run.status).to eq("done")
      expect(run.state["vars"]["t"]).to eq("eco: Oi Local")
      expect(run.state["vars"]["r"]).to include("provider" => "eco", "model" => "eco-1", "tokens" => 15)
      expect(seen.sole).to include(model: "eco-1", schema: nil, temperature: nil)
      call = AiCall.sole
      expect(call).to have_attributes(source: "automacao", provider: "eco", status: "ok", input_tokens: 10, automation_id: run.automation_id)
      expect(call.attributes.values.join).not_to include("Oi Local")
    end

    it "um tipo de consulta falso registrado funciona na ação e no helper Consulta" do
      median = Class.new(Datasets::Aggregates::Base) do
        describe key: "median", label: "Mediana", field: true
        def self.call(scope, field, _limit, _zone) = scope.pluck(:data).filter_map { |d| d[field] }.sort.then { |a| a[a.size / 2] }
      end
      stub_const("Datasets::Aggregates::Median", median)
      stub_const("Datasets::AGGREGATES", Datasets::AGGREGATES + %w[Median])
      [ 5, 1, 9 ].each { |m| dataset.record!({ "porta" => "a", "minutos" => m }) }
      run = fire([ { "type" => "dataset_query", "dataset" => dataset.id, "op" => "median", "field" => "minutos", "response_variable" => "q" } ])
      expect(run.state["vars"]["q"]).to eq("value" => 5)
      expect(Datasets.choices).to include("median" => "Mediana")

      helper = HelperTypes.build(site, HelperTypes::DatasetQuery)
      expect(HelperTypes.save(helper, { "name" => "Mediana", "dataset" => dataset.id, "op" => "median", "field" => "minutos" })).to be true
      expect(helper.reload.value).to eq(5)
      dataset.record!({ "porta" => "b", "minutos" => 20 })
      dataset.record!({ "porta" => "c", "minutos" => 30 })
      expect(helper.reload.value).to eq(9)
    end
  end

  describe "provedores reais (HTTP stubado)" do
    let(:png) { { media_type: "image/png", data: Base64.strict_encode64("png") } }

    it "Anthropic: imagem, saída estruturada, sem temperatura; chave recusada vira mensagem limpa" do
      stub = stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        headers: { "Content-Type" => "application/json" },
        body: { id: "m", type: "message", role: "assistant", model: "claude-haiku-5-5", stop_reason: "end_turn",
                content: [ { type: "text", text: '{"ok":true}' } ], usage: { input_tokens: 7, output_tokens: 3 } }.to_json
      )
      ModelPrice.seed_defaults!
      AiAccount.create!(provider: "anthropic", api_key: "sk-teste", model: "claude-haiku-5-5")
      res = Ai::Request.call(tenant: tenant, prompt: "olhe", source: "teste", images: [ png ], temperature: 0.5,
                             schema: { type: "object", properties: { ok: { type: "boolean" } }, required: [ "ok" ] })
      expect(res.data).to eq(ok: true)
      expect(res.cost).to be > 0
      expect(stub).to have_been_made
      body = nil
      expect(a_request(:post, "https://api.anthropic.com/v1/messages").with { |r| body = JSON.parse(r.body) }).to have_been_made
      expect(body["model"]).to eq("claude-haiku-5-5")
      expect(body["messages"][0]["content"][0]).to include("type" => "image")
      expect(body.dig("output_config", "format", "schema", "additionalProperties")).to be false
      expect(body).not_to have_key("temperature")

      stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(status: 401, body: { type: "error", error: { type: "authentication_error", message: "x" } }.to_json,
                                                                         headers: { "Content-Type" => "application/json" })
      expect { Ai::Request.call(tenant: tenant, prompt: "x", source: "teste") }.to raise_error(Ai::Client::Error, /chave do provedor foi recusada/)
      expect(AiCall.order(:created_at).last).to have_attributes(status: "error", provider: "anthropic")
    end

    it "OpenAI e Gemini: texto livre, imagem traduzida e temperatura só onde há" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(body: { choices: [ { message: { content: "Oi" } } ], usage: { prompt_tokens: 4, completion_tokens: 1 } }.to_json)
      AiAccount.create!(provider: "openai", api_key: "sk-o")
      expect(Ai::Request.call(tenant: tenant, prompt: "x", images: [ png ], provider: "openai", source: "teste", temperature: 1).data).to eq("Oi")
      expect(a_request(:post, "https://api.openai.com/v1/chat/completions").with { |r|
        b = JSON.parse(r.body)
        b["messages"][1]["content"][0]["image_url"]["url"].start_with?("data:image/png;base64,") && !b.key?("temperature") && !b.key?("response_format")
      }).to have_been_made

      stub_request(:post, %r{generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent})
        .to_return(body: { candidates: [ { content: { parts: [ { text: '{"n": 2}' } ] } } ], usageMetadata: { promptTokenCount: 3, candidatesTokenCount: 2 } }.to_json)
      AiAccount.create!(provider: "gemini", api_key: "g")
      res = Ai::Request.call(tenant: tenant, prompt: "x", provider: "gemini", source: "teste", temperature: 0.2,
                             schema: { type: "object", properties: { n: { type: "integer" } } })
      expect(res.data).to eq(n: 2)
      expect(a_request(:post, /generateContent/).with { |r| JSON.parse(r.body).dig("generationConfig", "temperature") == 0.2 }).to have_been_made

      stub_request(:post, /generateContent/).to_return(status: 503, body: "caiu")
      expect { Ai::Request.call(tenant: tenant, prompt: "x", provider: "gemini", source: "teste") }.to raise_error(Ai::Client::TransientError)
    end

    it "Ollama: URL do usuário pelo SafeHttp (rede de casa só liberada), imagens e format" do
      AiAccount.create!(provider: "ollama", base_url: "http://192.168.68.50:11434", model: "llava")
      expect { Ai::Request.call(tenant: tenant, prompt: "x", source: "teste") }.to raise_error(Ai::Client::Error, /bloqueado/)
      tenant.update!(http_allow_text: "192.168.68.50")
      stub_request(:post, "http://192.168.68.50:11434/api/chat")
        .to_return(body: { message: { content: '{"pessoas": 1}' }, prompt_eval_count: 30, eval_count: 4 }.to_json)
      res = Ai::Request.call(tenant: tenant, prompt: "quantas pessoas?", source: "teste", images: [ png ], temperature: 0,
                             schema: { type: "object", properties: { pessoas: { type: "integer" } } })
      expect(res).to have_attributes(data: { pessoas: 1 }, model: "llava", cost: 0.0)
      expect(a_request(:post, "http://192.168.68.50:11434/api/chat").with { |r|
        b = JSON.parse(r.body)
        b["messages"][1]["images"] == [ png[:data] ] && b["format"]["type"] == "object" && b["options"]["temperature"].zero? && b["stream"] == false
      }).to have_been_made
    end
  end

  describe "Ai::Request: escolha, capacidades, limite e registro" do
    it "sem provedor configurado, mensagem que leva às Configurações" do
      expect { Ai::Request.call(tenant: tenant, prompt: "x", source: "teste") }.to raise_error(Ai::Client::Error, /Configurações → IA/)
      expect { Ai::Request.call(tenant: tenant, prompt: "x", source: "teste", provider: "openai") }.to raise_error(Ai::Client::Error, /OpenAI/)
    end

    it "provedor sem imagem ou sem saída estruturada recusa antes de chamar" do
      seen = fake_provider!(capabilities: %i[text])
      img = [ { media_type: "image/jpeg", data: "eA==" } ]
      expect { Ai::Request.call(tenant: tenant, prompt: "x", source: "teste", images: img) }.to raise_error(Ai::Client::Error, /não aceita imagem/)
      expect { Ai::Request.call(tenant: tenant, prompt: "x", source: "teste", schema: { type: "object" }) }.to raise_error(Ai::Client::Error, /saída estruturada/)
      expect(seen).to be_empty
      expect(AiCall.pluck(:status)).to eq(%w[error error])
    end

    it "limite do mês bloqueia com aviso (uma vez por mês) e registra bloqueada" do
      fake_provider!
      owner
      Ai::Budget.save!(tenant, { limit_calls: "2", limit_usd: "", default_provider: "eco" })
      2.times { Ai::Request.call(tenant: tenant, prompt: "x", source: "teste") }
      budget = Ai::Budget.for(tenant.reload)
      expect([ budget.calls, budget.exceeded?, budget.ratio, budget.default_provider ]).to eq([ 2, true, 1.0, "eco" ])
      2.times { expect { Ai::Request.call(tenant: tenant, prompt: "x", source: "teste") }.to raise_error(Ai::Request::LimitReached) }
      expect(Notification.where(title: "Limite mensal da IA atingido").count).to eq(1)
      expect(AiCall.where(status: "blocked").count).to eq(2)
      expect(Ai::Budget.for(tenant).calls).to eq(2) # bloqueada não conta

      Ai::Budget.save!(tenant, { limit_usd: "0,50" })
      expect(Ai::Budget.for(tenant.reload)).to have_attributes(limit_usd: 0.5, limit_calls: nil, exceeded?: false)
      travel(1.month) { expect(Ai::Budget.for(tenant).calls).to eq(0) }
    end
  end

  describe "ação Pedir à IA" do
    it "saída estruturada pelos campos, sistema, imagens de câmera, URL e anexo" do
      seen = fake_provider!(capabilities: %i[text image structured temperature])
      temp
      cam = create(:point, device: create(:device, site: site, driver: "go2rtc"), key: "entrada.cam", capability: "stream", name: "Entrada")
      allow(Drivers::Go2rtc).to receive(:snapshot).and_return("\xFF\xD8jpeg".b)
      stub_request(:get, "https://img.exemplo.com/a.png").to_return(body: "png", headers: { "Content-Type" => "image/png" })
      stub_request(:get, "https://img.exemplo.com/b.txt").to_return(body: "x", headers: { "Content-Type" => "text/plain" })
      allow(SafeHttp).to receive(:lookup).and_return([ "93.184.216.34" ])
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("gif"), filename: "a.gif", content_type: "image/gif")
      blob_url = Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
      output = Ai::Output.parse("resumo: texto O que viu\nanomalia: sim/não")
      run = fire([ { "type" => "ai_task", "prompt" => "Veja {{ points[\"sala.temp\"].text }}", "system" => "Seja breve", "cameras" => [ "entrada.cam" ],
                     "image_urls" => "https://img.exemplo.com/a.png\n#{blob_url}\nhttps://img.exemplo.com/b.txt", "output" => output,
                     "temperature" => 0.3, "max_tokens" => 200, "response_variable" => "ia" },
                   { "type" => "if", "conditions" => [ { "type" => "expr", "expr" => "ia.data.anomalia" } ],
                     "then" => [ { "type" => "set", "var" => "x", "expr" => "1" } ], "else" => [ { "type" => "set", "var" => "x", "expr" => "2" } ] } ])
      expect(run.status).to eq("done")
      expect(run.state["vars"]["x"]).to eq(2)
      expect(run.state["vars"]["ia"]["data"]).to eq("resumo" => "tudo certo", "anomalia" => false)
      got = seen.sole
      expect(got[:user].count { |b| b[:type] == "image" }).to eq(3)
      expect(got[:user].last[:text]).to include("Veja 24,5")
      expect(got).to include(system: "Seja breve", temperature: 0.3, max_tokens: 200)
      expect(got[:schema][:required]).to eq(%w[resumo anomalia])
      step = run.steps.find { |s| s["title"] == "Pedir à IA" }
      expect(step["detail"]).to include("Eco de teste · eco-1 · 15 tokens", "3 imagem(ns)", "não é imagem")
      expect(cam).to be_persisted
    end

    it "erro da IA para a execução ou é tolerado; simulação não chama; validação dos campos" do
      run = fire([ { "type" => "ai_task", "prompt" => "x" } ])
      expect(run).to have_attributes(status: "failed")
      expect(run.error).to include("IA: Nenhum provedor")
      run = fire([ { "type" => "ai_task", "prompt" => "x", "continue_on_error" => true }, { "type" => "set", "var" => "d", "expr" => "1" } ])
      expect(run.status).to eq("done")

      seen = fake_provider!
      sim = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "ai_task", "prompt" => "x" } ] }).simulate!
      expect(sim.steps.pluck("result")).to include("simulated")
      expect(seen).to be_empty

      bad = { "triggers" => [ { "type" => "manual" } ],
              "actions" => [ { "type" => "ai_task", "prompt" => "x", "temperature" => 5, "max_tokens" => 0, "provider" => "nada",
                               "output" => [ { "invalid" => "foo" } ] },
                             { "type" => "ai_data", "prompt" => "y" } ] }
      errors = Automations::Dsl.errors(bad, site).join(" | ")
      expect(errors).to include("temperatura de 0 a 2", "limite de tokens", "opção inválida", "linha inválida \"foo\"", "escolha pontos, áreas ou etiquetas")
    end

    it "Gerar dados por IA põe o estado e o resumo do histórico dos pontos escolhidos (por área e etiqueta)" do
      seen = fake_provider!
      tag = Tag.create!(name: "iluminacao")
      Tagging.create!(tag: tag, taggable: lamp)
      Reading.insert_all!([ { point_id: temp.id, at: 2.hours.ago, value: 20 }, { point_id: temp.id, at: 1.hour.ago, value: 28 } ])
      other = create(:point, device: device, key: "fora.x", name: "Fora do contexto", capability: "onoff", value: false)
      fire([ { "type" => "ai_data", "areas" => [ area.id ], "tags" => [ tag.id ], "history" => "24h", "prompt" => "Algo estranho?" } ])
      text = seen.sole[:user]
      expect(text).to include("Estado de Local", "Temperatura [sala.temp] (Sala): 24,5", "2 leituras, mín 20, máx 28, média 24", "Luz [sala.luz]", "Algo estranho?")
      expect(text).not_to include(other.name)
      expect(Ai::PointContext.text(Automations::Context.new(site: create(:site)))).to eq("Nenhum ponto no contexto.")
    end
  end

  describe "conjuntos de dados" do
    it "Registrar dados converte pelos tipos, devolve a linha e recusa campo desconhecido" do
      run = fire([ { "type" => "dataset_record", "dataset" => dataset.id, "values" => { "porta" => "{{ site.name }}", "minutos" => "2,5", "ok" => "true" },
                     "response_variable" => "linha" } ])
      expect(run.status).to eq("done")
      expect(dataset.records.sole.data).to eq("porta" => "Local", "minutos" => 2.5, "ok" => true)
      expect(run.state["vars"]["linha"]).to include("porta" => "Local", "em" => be_present)

      run = fire([ { "type" => "dataset_record", "dataset" => dataset.id, "values" => { "cor" => "azul" } } ])
      expect(run.error).to include("campo desconhecido: cor")
      run = fire([ { "type" => "dataset_record", "dataset" => dataset.id, "values" => { "minutos" => "muito" } } ])
      expect(run.error).to include("não é número")
      expect(build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "dataset_record", "dataset" => dataset.id, "values" => { "porta" => "x" } } ] })
               .simulate!.steps.pluck("result")).to include("simulated")
    end

    it "conjunto livre reconhece número; tipos de campo e chave validados" do
      free = Dataset.create!(site: site, name: "Livre Total")
      expect(free.key).to eq("livre_total")
      free.record!({ "a" => "3", "b" => "texto", "c" => "2026-11-01" })
      expect(free.records.sole.data).to eq("a" => 3, "b" => "texto", "c" => "2026-11-01")
      expect { free.record!({}) }.to raise_error(ArgumentError, /nenhum valor/)
      expect { free.record!({ "A B" => 1 }) }.to raise_error(ArgumentError, /desconhecido/)
      typed = Dataset.new(site: site, name: "T", fields_text: "quando: data\nx: cor\nx: texto")
      expect(typed).not_to be_valid
      expect(typed.errors.full_messages.join).to include("inválido", "repetido")
      ds = Dataset.create!(site: site, name: "Horas", fields_text: "quando: data")
      ds.record!({ "quando" => "2026-11-01 10:00" })
      expect(ds.records.sole.data["quando"]).to start_with("2026-11-01T10:00:00")
      expect { ds.record!({ "quando" => "ontem à tarde" }) }.to raise_error(ArgumentError, /não é data/)
      expect(ds.fields_text).to eq("quando: data e hora")
    end

    it "Consultar dados: todos os tipos de consulta, janela e filtros" do
      travel_to Time.zone.parse("2026-11-02 10:00")
      dataset.records.create!(data: { "porta" => "garagem", "minutos" => 30, "ok" => true }, created_at: 3.days.ago)
      dataset.records.create!(data: { "porta" => "garagem", "minutos" => 5, "ok" => false }, created_at: 2.hours.ago)
      dataset.records.create!(data: { "porta" => "Social", "minutos" => 15, "ok" => true }, created_at: 1.hour.ago)
      q = ->(op, **kw) { Datasets::Query.new(dataset, op: op, **kw).call }
      expect(q.("count")).to eq(3)
      expect(q.("sum", field: "minutos")).to eq(50)
      expect(q.("avg", field: "minutos", window_s: 86_400)).to eq(10)
      expect([ q.("min", field: "minutos"), q.("max", field: "minutos") ]).to eq([ 5, 30 ])
      expect(q.("sum", field: "minutos", filters: "porta = nada")).to eq(0)
      expect(q.("last", field: "porta")).to eq("Social")
      expect(q.("last")).to include("porta" => "Social", "minutos" => 15)
      expect(q.("count", filters: "porta contém GAR\nminutos > 10")).to eq(1)
      expect(q.("count", filters: "porta != garagem")).to eq(1)
      expect(q.("count", filters: "minutos >= 15\nminutos <= 15")).to eq(1)
      expect(q.("count", filters: "minutos < 6")).to eq(1)
      expect(q.("rows", limit: 2).pluck("porta")).to eq(%w[Social garagem])
      expect { q.("nada") }.to raise_error(ArgumentError, /não existe/)
      expect { q.("sum") }.to raise_error(ArgumentError, /informe o campo/)
      expect { q.("count", filters: "porta ~ x") }.to raise_error(ArgumentError, /filtro inválido/)

      run = fire([ { "type" => "dataset_query", "dataset" => dataset.id, "op" => "rows", "window" => "24h", "filters" => "porta = {{ \"garagem\" }}", "limit" => 10,
                     "response_variable" => "dados" },
                   { "type" => "set", "var" => "lista", "value" => "{% for r in dados.rows %}{{ r.porta }}:{{ r.minutos }};{% endfor %}{{ dados.count }}" } ])
      expect(run.state["vars"]["lista"]).to eq("garagem:5;1")
      bad = { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "dataset_query", "dataset" => dataset.id, "op" => "sum", "filters" => "x ? y", "limit" => 9999 },
                                                                       { "type" => "dataset_query", "dataset" => SecureRandom.uuid, "op" => "count" } ] }
      expect(Automations::Dsl.errors(bad, site).join(" | ")).to include("informe o campo", "filtro inválido", "máximo de linhas", "conjunto de dados não existe")
    end

    it "retenção apaga só o que passou do prazo; zerar leva conjuntos e registros" do
      dataset.update!(retention_days: 7)
      dataset.records.create!(data: { "porta" => "velha" }, created_at: 8.days.ago)
      dataset.record!({ "porta" => "nova" })
      ReadingsMaintenanceJob.perform_now
      expect(dataset.records.pluck(:data)).to eq([ { "porta" => "nova" } ])
      Accounts::WipeData.call(tenant)
      expect([ Dataset.count, DatasetRecord.count ]).to eq([ 0, 0 ])
    end

    it "helper Consulta: validação, texto no último valor de texto e erro vira qualidade" do
      fails = lambda do |form|
        h = HelperTypes.build(site, HelperTypes::DatasetQuery)
        expect(HelperTypes.save(h, { "name" => "X" }.merge(form))).to be false
        h.errors.full_messages.join
      end
      expect(fails.({})).to include("Escolha o conjunto")
      expect(fails.({ "dataset" => dataset.id, "op" => "rows" })).to include("Escolha a consulta")
      expect(fails.({ "dataset" => dataset.id, "op" => "sum" })).to include("Informe o campo")
      expect(fails.({ "dataset" => dataset.id, "op" => "count", "window" => "abc" })).to include("Janela inválida")
      expect(fails.({ "dataset" => dataset.id, "op" => "count", "filters" => "quebrado" })).to include("Filtro inválido")
      h = HelperTypes.build(site, HelperTypes::DatasetQuery)
      expect(HelperTypes.save(h, { "name" => "Última porta", "dataset" => dataset.id, "op" => "last", "field" => "porta", "window" => "24h" })).to be true
      expect(h.reload).to have_attributes(capability: "text", value: nil)
      dataset.record!({ "porta" => "garagem" })
      expect(h.reload.value).to eq("garagem")
      expect(HelperTypes::DatasetQuery.summary(h)).to eq("Último valor · porta · 24 h")
      h.update!(address: h.address.merge("op" => "nada"))
      HelperTypes::DatasetQuery.refresh!(h)
      expect(h.reload.quality).to eq("error")
      dataset.destroy!
      HelperTypes::DatasetQuery.refresh!(h)
      expect(h.reload.quality).to eq("unavailable")
    end
  end

  describe "saída estruturada (texto do editor)" do
    it "campos por linha, JSON schema e erros" do
      expect(Ai::Output.parse("")).to be_nil
      list = Ai::Output.parse("Total: Número quantas\nitens: lista")
      expect(list).to eq([ { "name" => "total", "type" => "numero", "description" => "quantas" }, { "name" => "itens", "type" => "lista" } ])
      expect(Ai::Output.error(list)).to be_nil
      expect(Ai::Output.text(list)).to eq("total: numero quantas\nitens: lista")
      expect(Ai::Output.schema(list)[:properties]["itens"]).to eq(type: "array", items: { type: "string" })
      schema = Ai::Output.parse('{"type":"object","properties":{"a":{"type":"string"}}}')
      expect([ Ai::Output.error(schema), Ai::Output.schema(schema) ]).to eq([ nil, schema ])
      expect(Ai::Output.text(schema)).to include('"type": "object"')
      expect(Ai::Output.error(Ai::Output.parse("{quebrado"))).to include("JSON schema inválido")
      expect(Ai::Output.error({ "type" => "string" })).to include("objeto")
      expect(Ai::Output.error([ { "name" => "a", "type" => "texto" } ] * 2)).to eq("campo repetido")
      expect(Ai::Output.error("x")).to include("um campo por linha")
    end
  end
end
