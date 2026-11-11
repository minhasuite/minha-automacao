# ESPresense pelo MQTT (Mqtt::Listener::DISCOVERY). As placas mandam muitas
# mensagens por segundo; por isso a conta é na memória do ouvinte e o banco
# só é tocado quando o cômodo de um aparelho listado muda. Plugin em
# Integrations::EspresensePlugin.
module Espresense
  AWAY = "not_home".freeze # mesmo valor do ESPresense/HA: fora do alcance das placas
  CACHE_S = 60

  @lock = Mutex.new
  @seen = Hash.new { |h, k| h[k] = {} } # [prefixo, id] → {cômodo → [distância, relógio]}
  @companion = {}                       # [prefixo, id] → [cômodo, relógio]
  @reported = {}                        # ponto → valor já gravado

  module_function

  def room_id(name) = I18n.transliterate(name.to_s).downcase.strip.gsub(/[^a-z0-9]+/, "_").delete_prefix("_").delete_suffix("_")
  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Integrações por prefixo, com cache curto (não consultar a cada mensagem).
  def integrations
    @lock.synchronize do
      if @cached.nil? || clock - @cached_at > CACHE_S
        @cached = ActsAsTenant.without_tenant { Integration.where(driver: "espresense").to_a }
        @cached_at = clock
      end
      @cached
    end
  end

  def reset!
    @lock.synchronize do
      @cached = nil
      @seen.clear
      @companion.clear
      @reported.clear
    end
  end

  def prefix_of(i) = Integrations::EspresensePlugin.prefix(i)
  def topics = integrations.map { |i| prefix_of(i) }.uniq.flat_map { |t| [ "#{t}/devices/+/+", "#{t}/companion/+" ] }
  def handles?(topic) = integrations.any? { |i| topic.start_with?("#{prefix_of(i)}/devices/", "#{prefix_of(i)}/companion/") }

  def handle(topic, payload)
    integrations.each do |i|
      prefix = prefix_of(i)
      rest = topic.delete_prefix("#{prefix}/").split("/")
      next if rest.size < 2 || "#{prefix}/#{rest.join('/')}" != topic

      id = rest[1]
      next unless Integrations::EspresensePlugin.tracked(i).any? { |tid, _| tid == id }

      if rest[0] == "devices" && rest.size == 3
        msg = JSON.parse(payload.to_s)
        dist = Float(msg["distance"].to_s, exception: false) if msg.is_a?(Hash)
        @lock.synchronize { @seen[[ prefix, id ]][room_id(rest[2])] = [ dist, clock ] } if dist
      elsif rest[0] == "companion" && rest.size == 2
        @lock.synchronize { @companion[[ prefix, id ]] = [ companion_room(payload), clock ] }
      else
        next
      end
      refresh!(i, id)
    end
  rescue JSON::ParserError
    nil
  end

  def companion_room(payload)
    msg = JSON.parse(payload.to_s)
    room = msg.is_a?(Hash) ? msg["room"] || msg["state"] : msg
    room.to_s.presence || AWAY
  rescue JSON::ParserError
    payload.to_s.strip.presence || AWAY
  end

  # → [cômodo, distância] de agora para o aparelho.
  def current(prefix, id, integration)
    timeout = Integrations::EspresensePlugin.conf(integration, :timeout_s).to_f.clamp(5, 600)
    max = Integrations::EspresensePlugin.conf(integration, :max_distance).to_f.clamp(0.5, 50)
    @lock.synchronize do
      comp = @companion[[ prefix, id ]]
      return [ comp[0] == AWAY ? AWAY : room_id(comp[0]), nil ] if comp && clock - comp[1] <= timeout

      best = @seen[[ prefix, id ]].select { |_, (d, t)| clock - t <= timeout && d <= max }.min_by { |_, (d, _)| d }
      best ? [ best[0], best[1][0].round(1) ] : [ AWAY, nil ]
    end
  end

  def occupied?(prefix, room, integration)
    Integrations::EspresensePlugin.tracked(integration).any? { |id, _| current(prefix, id, integration)[0] == room }
  end

  # Grava só o que mudou: cômodo do aparelho e a ocupação dos cômodos.
  def refresh!(integration, id)
    prefix = prefix_of(integration)
    room, _dist = current(prefix, id, integration)
    key = [ prefix, id ]
    return if @lock.synchronize { @reported[key] } == room

    @lock.synchronize { @reported[key] = room }
    ActsAsTenant.with_tenant(integration.tenant) do
      devices = integration.devices.where(disabled: false, removed_at: nil).includes(:points).to_a
      devices.select { |d| d.address["id"] == id }.each do |d|
        d.update_columns(status: "online", last_seen_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        d.points.each { |p| p.report!(room) if p.address["field"] == "room" && !p.disabled }
      end
      devices.select { |d| d.address["room"] }.each do |d|
        busy = occupied?(prefix, d.address["room"], integration)
        d.points.each { |p| p.report!(busy) if p.address["field"] == "occupied" && !p.disabled && p.value != busy }
      end
    end
  end
end
