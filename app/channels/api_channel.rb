# API WebSocket (ondaA2 A17): comandos do `WsApi` pelo /cable (mesma
# conexão da web e do app: cookie ou `?access_token=`). Cada local tem no
# máximo duas escutas por conexão (pontos e eventos de automação); as
# assinaturas da pessoa (`subscribe_events`) só filtram o que chega.
class ApiChannel < ActionCable::Channel::Base
  def subscribed
    @subs = {}
    @streams = Set.new
  end

  # data: {"action" => "command", "id" => 1, "type" => "ping", ...}
  def command(data)
    transmit(WsApi.handle(WsApi::Ctx.new(user: current_user, channel: self), data.except("action")))
  end

  def subscribe_events(id, site, type)
    raise WsApi::Error.new(:invalid, "id required") if id.nil?
    raise WsApi::Error.new(:invalid, "id already in use") if @subs.key?(id)

    @subs[id] = { site_id: site.id, type: type.to_s }
    listen(site)
  end

  def unsubscribe_events(id) = @subs.delete(id)

  private

  def listen(site)
    return unless @streams.add?(site.id)

    # Pontos: o mesmo aviso dos painéis (Turbo, só o id); sem escrita a mais no Solid Cable.
    stream_from("#{site.to_gid_param}:points", ->(msg) { point_changed(site.id, msg) })
    stream_from(WsApi.events_stream(site.id), ->(ev) { deliver(site.id, ev["event_type"], ev) }, coder: ActiveSupport::JSON)
  end

  def point_changed(site_id, msg)
    id = msg.to_s[/target=\\?"([0-9a-f-]{36})\\?"/, 1] or return
    state = ActsAsTenant.with_tenant(current_user.tenant) { Point.find_by(id: id)&.then { |p| WsApi.state(p) } } or return
    deliver(site_id, "state_changed", WsApi.event("state_changed", state, site_id))
  end

  def deliver(site_id, type, event)
    @subs.each do |id, s|
      next unless s[:site_id] == site_id && (s[:type] == "*" || s[:type] == type)

      transmit({ "id" => id, "type" => "event", "event" => event })
    end
  end
end
