module ApiHelpers
  def auth_headers(user)
    _token, access, = ApiToken.issue(user)
    { "Authorization" => "Bearer #{access}" }
  end

  def json = JSON.parse(response.body)
  def data = json["data"]

  # Executa o bloco dentro da empresa (factories de dado tenant-scoped).
  def within(tenant, &) = ActsAsTenant.with_tenant(tenant, &)
end

RSpec.configure do |config|
  config.include ApiHelpers
end
