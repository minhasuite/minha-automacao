module ApiHelpers
  def auth_headers(user)
    _token, access, = ApiToken.issue(user)
    { "Authorization" => "Bearer #{access}" }
  end

  def json = JSON.parse(response.body)
  def data = json["data"]

  # Executa o bloco dentro da empresa (factories de dado tenant-scoped).
  def within(tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  # IA ligada nos specs (sem rede: o Ai::Client é stubado por exemplo).
  def enable_ai!
    allow(Ai::Provider).to receive(:configured?).and_return(true)
  end

  # A próxima chamada à IA devolve `data`.
  def stub_ai(data)
    client = instance_double(Ai::Client, complete: ai_response(data))
    allow(Ai::Client).to receive(:new).and_return(client)
    client
  end

  def ai_response(data, model: "claude-test")
    Ai::Client::Response.new(data: data, model: model, usage: { input: 100, output: 50 })
  end
end

RSpec.configure do |config|
  config.include ApiHelpers
end
