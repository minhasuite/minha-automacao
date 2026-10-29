require "webmock/rspec"

# Spec nunca sai para a internet: Google Play, licenças, FCM e IA são todos
# stubados.
WebMock.disable_net_connect!(allow_localhost: true)

# DNS também não sai: todo host "resolve" para um IP público de exemplo,
# exceto IP literal (que resolve para ele mesmo — o teste de SSRF usa isso).
RSpec.configure do |config|
  config.before do
    allow(Resolv).to receive(:getaddresses).and_wrap_original do |_original, host|
      host.match?(/\A[\d.]+\z|:/) ? [ host ] : [ "93.184.216.34" ]
    end
  end
end

# Como no devcontainer: os links dos e-mails apontam para o host local.
ENV["APP_HOST"] = "localhost:4121"
