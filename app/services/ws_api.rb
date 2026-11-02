# API WebSocket (ondaA2 A17; a "WebSocket API" do HA) sobre o /cable: o
# cliente assina o canal `ApiChannel` e manda comandos `{id, type, ...}`;
# cada resposta volta como `{id, type: "result", success, result | error}` e
# cada evento assinado como `{id, type: "event", event: {...}}`.
# Comando = classe `< WsApi::Command` com `describe type:` e `call(ctx, msg)`
# + nome em `COMMANDS`; o canal só pergunta ao registro. Protocolo em
# docs/api/websocket.md.
module WsApi
  COMMANDS = %w[Ping GetConfig GetStates GetCommands CallCommand SubscribeEvents UnsubscribeEvents FireEvent RenderTemplate].freeze
  Error = Class.new(StandardError) do
    attr_reader :code

    def initialize(code, message = code.to_s.tr("_", " "))
      @code = code.to_s
      super(message)
    end
  end

  # O que o comando recebe: a pessoa, o canal (para assinar) e ajudas de acesso.
  Ctx = Data.define(:user, :channel) do
    def site(id)
      ActsAsTenant.with_tenant(user.tenant) { Site.find_by(id: id) }.then { |s| s&.role_for(user) ? s : raise(Error.new(:not_found, "site not found")) }
    end

    def sites = ActsAsTenant.with_tenant(user.tenant) { Site.order(:name).to_a.select { |s| s.role_for(user) } }
    def tenant(&) = ActsAsTenant.with_tenant(user.tenant, &)
  end

  class Command
    class << self
      attr_reader :type

      def describe(type:) = @type = type
      def call(_ctx, _msg) = raise(NotImplementedError)
    end
  end

  module_function

  def commands = COMMANDS.map { |n| Commands.const_get(n) }
  def command(type) = commands.find { |c| c.type == type.to_s }

  # → resposta para o `transmit` (nunca levanta: erro vira `success: false`).
  def handle(ctx, msg)
    id = msg["id"]
    cmd = command(msg["type"]) or raise Error.new(:unknown_command, "unknown command: #{msg['type']}")
    { "id" => id, "type" => "result", "success" => true, "result" => cmd.call(ctx, msg) }
  rescue Error => e
    { "id" => id, "type" => "result", "success" => false, "error" => { "code" => e.code, "message" => e.message } }
  rescue Points::Command::Error, SiteMembership::Forbidden, ArgumentError => e
    { "id" => id, "type" => "result", "success" => false, "error" => { "code" => "invalid", "message" => e.message } }
  end

  def state(p) = DevTools.state_json(p).merge("site_id" => p.site_id, "unit" => p.unit)
  def event(name, data, site_id) = { "event_type" => name, "data" => data, "site_id" => site_id, "time_fired" => Time.current.iso8601(3) }
  def events_stream(site_id) = "api_events:#{site_id}"

  # Eventos de automação (os mesmos da aba Eventos) para quem assinou pela API.
  def broadcast(site_id, name, payload) = ActionCable.server.broadcast(events_stream(site_id), event(name, payload, site_id))
end
