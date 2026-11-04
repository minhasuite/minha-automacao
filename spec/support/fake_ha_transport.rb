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

  # Com parâmetros (ex. `lovelace/config` + url_path): a chave é "tipo valor".
  def ws(type, **params)
    key = ([ type ] + params.values.map(&:to_s)).join(" ")
    @calls << key
    @fx["ws"].fetch(key) { @fx["ws"].fetch(type) { raise Integrations::Error, "sem #{key}" } }
  end
end
