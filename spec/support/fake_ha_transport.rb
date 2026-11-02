# HA falso (assistente "Migre do HA"): responde pelos caminhos REST e comandos WebSocket da fixture.
class FakeHaTransport
  attr_reader :calls

  def initialize(fixture, fail_on: nil)
    @fx = fixture
    @fail_on = fail_on
    @calls = []
  end

  def get(path)
    @calls << path
    raise Integrations::Error, "HTTP 500" if path == @fail_on

    @fx["rest"].fetch(path) { raise Integrations::Error, "HTTP 404" }
  end

  def ws(type)
    @calls << type
    @fx["ws"].fetch(type)
  end
end
