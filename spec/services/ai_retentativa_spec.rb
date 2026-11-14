require "rails_helper"

# "IA fora do ar" (paineis-ia): a falha passageira (429, 529 overloaded, 5xx, tempo esgotado) ganha nova
# tentativa com espera; a resposta cortada no max_tokens (o raciocínio também conta) tenta com o dobro; o
# AiCall guarda o motivo técnico (status e tipo, nunca prompt nem resposta) e quantas tentativas levou.
RSpec.describe Ai::Request do
  let(:tenant) { create(:tenant) }
  let!(:site) { within(tenant) { create(:site) } }
  let(:url) { "https://api.anthropic.com/v1/messages" }
  let(:waits) { [] }

  before do
    within(tenant) { AiAccount.create!(provider: "anthropic", api_key: "sk-teste", model: "claude-haiku-5-5") }
    described_class.sleeper = ->(s) { waits << s }
  end

  def message(text, stop: "end_turn", output: 20)
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "m", type: "message", role: "assistant", model: "claude-haiku-5-5", stop_reason: stop,
              content: [ { type: "text", text: text } ], usage: { input_tokens: 100, output_tokens: output } }.to_json }
  end

  def failure(status, type, headers: {})
    { status: status, headers: { "Content-Type" => "application/json" }.merge(headers),
      body: { type: "error", error: { type: type, message: "segredo do provedor" } }.to_json }
  end

  def ask(source: "automacao", schema: nil, max_tokens: nil)
    within(tenant) do
      described_class.call(tenant: tenant, site: site, source: source, prompt: "Prompt secreto da casa", schema: schema, max_tokens: max_tokens)
    end
  end

  def last_call = within(tenant) { AiCall.order(:created_at).last }

  it "529 overloaded e depois ok: responde, um AiCall só, ok com 2 tentativas e o motivo" do
    stub_request(:post, url).to_return(failure(529, "overloaded_error"), message("tudo certo"))
    expect(ask.data).to eq("tudo certo")
    expect(within(tenant) { AiCall.count }).to eq(1)
    expect(last_call).to have_attributes(status: "ok", attempts: 2, detail: "HTTP 529 overloaded_error", error: nil)
    expect(waits.size).to eq(1)
  end

  it "429 com retry-after: espera o que o provedor pediu (até o teto)" do
    stub_request(:post, url).to_return(failure(429, "rate_limit_error", headers: { "retry-after" => "5" }), message("ok"))
    ask
    expect(waits.first).to be_between(5, 5.5)
    expect(last_call.detail).to eq("HTTP 429 rate_limit_error")
  end

  it "falha que persiste: 3 tentativas na automação, erro com o motivo e sem o corpo do provedor" do
    stub_request(:post, url).to_return(failure(500, "api_error"))
    expect { ask }.to raise_error(Ai::Client::TransientError, /não conseguiu responder/)
    expect(a_request(:post, url)).to have_been_made.times(3)
    expect(last_call).to have_attributes(status: "error", attempts: 3, detail: "HTTP 500 api_error")
    expect(last_call.attributes.values.join).not_to include("segredo do provedor", "Prompt secreto")
  end

  it "com alguém olhando (pergunta), só uma retentativa curta" do
    stub_request(:post, url).to_return(failure(503, "api_error"))
    expect { ask(source: "pergunta") }.to raise_error(Ai::Client::TransientError)
    expect(a_request(:post, url)).to have_been_made.times(2)
    expect(waits.size).to eq(1)
  end

  it "tempo esgotado também tenta de novo e fica registrado" do
    stub_request(:post, url).to_timeout.then.to_return(message("ok"))
    expect(ask.data).to eq("ok")
    expect(last_call.detail).to start_with("tempo esgotado").or start_with("conexão")
  end

  it "erro que não é passageiro (400) não tenta de novo" do
    stub_request(:post, url).to_return(failure(400, "invalid_request_error"))
    expect { ask }.to raise_error(Ai::Client::Error) { |e| expect(e).not_to be_a(Ai::Client::TransientError) }
    expect(a_request(:post, url)).to have_been_made.once
    expect(last_call).to have_attributes(attempts: 1, detail: "HTTP 400 invalid_request_error")
  end

  it "saída estruturada cortada no max_tokens: tenta com o dobro, soma os tokens e guarda o motivo" do
    schema = { type: "object", properties: { severidade: { type: "string" } }, required: %w[severidade] }
    stub_request(:post, url).to_return(message('{"severidade": "nor', stop: "max_tokens", output: 1000), message('{"severidade": "normal"}', output: 300))
    res = ask(schema: schema, max_tokens: 1000)
    expect(res.data).to eq({ severidade: "normal" })
    expect(a_request(:post, url).with { |r| JSON.parse(r.body)["max_tokens"] == 2000 }).to have_been_made.once
    expect(last_call).to have_attributes(status: "ok", attempts: 2, output_tokens: 1300, detail: "stop_reason max_tokens (limite 1000, saída 1000)")
  end

  it "padrão: max_tokens com folga para o raciocínio (16000)" do
    stub_request(:post, url).to_return(message("ok"))
    ask
    expect(a_request(:post, url).with { |r| JSON.parse(r.body)["max_tokens"] == 16_000 }).to have_been_made
  end

  it "JSON inválido sem corte: erro com o motivo e os tokens gastos" do
    stub_request(:post, url).to_return(message("não é json", output: 7))
    expect { ask(schema: { type: "object", properties: {} }) }.to raise_error(Ai::Client::Error, /formato inesperado/)
    expect(last_call).to have_attributes(status: "error", output_tokens: 7)
    expect(last_call.detail).to start_with("JSON inválido")
  end

  describe "na automação (o Vigia da casa)" do
    def vigia
      a = within(tenant) { Automation.create!(site: site, name: "Casa | IA | Vigia #{SecureRandom.hex(2)}", kind: "automation", mode: "single") }
      within(tenant) do
        a.publish!({ "triggers" => [ { "type" => "manual" } ],
                     "actions" => [ { "type" => "ai_task", "prompt" => "Julgue", "output" => [ { "name" => "severidade", "type" => "texto", "description" => "normal ou critico" } ],
                                      "continue_on_error" => true, "response_variable" => "analise" },
                                    { "type" => "if", "conditions" => [ { "type" => "expr", "expr" => "not(defined('analise.data'))" } ],
                                      "then" => [ { "type" => "trace_note", "message" => "IA FORA DO AR" } ] } ] })
        a.update!(enabled: true)
      end
      a
    end

    def fire = within(tenant) { vigia.fire!({ "type" => "manual" }) }

    it "falha passageira que a nova tentativa resolve não chega ao aviso de IA fora do ar" do
      stub_request(:post, url).to_return(failure(529, "overloaded_error"), message('{"severidade": "normal"}'))
      run = fire
      expect(run.status).to eq("done")
      expect(run.steps.to_json).not_to include("IA FORA DO AR")
    end

    it "falha que persiste ainda avisa" do
      stub_request(:post, url).to_return(failure(529, "overloaded_error"))
      run = fire
      expect(run.steps.to_json).to include("IA FORA DO AR")
    end
  end
end
