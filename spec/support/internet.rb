# voz-offline: por padrão os specs "têm internet" sem sair para a rede.
# O spec de modo offline chama o probe de verdade com a nuvem bloqueada (WebMock).
RSpec.configure do |config|
  config.before do
    Internet.reset!
    allow(Internet).to receive(:probe).and_return(true)
  end
end
