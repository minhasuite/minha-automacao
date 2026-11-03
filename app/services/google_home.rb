# Google Home cloud-to-cloud (ondaC1, C6; o `google_assistant` do HA): o
# Google chama POST /google/smart_home com o token do account linking
# (`ApiToken` de cliente "google", o mesmo OAuth da Alexa) e as intenções
# SYNC, QUERY, EXECUTE e DISCONNECT. Só entra o ponto marcado na tela Expor
# (coluna Google, `expose.google`); o comando sai pelo Points::Command com o
# papel da pessoa × risco, `source: "google"`. Melhor que o HA: ponto
# crítico (portão) pede a confirmação de voz do próprio Google (desafio
# `ackNeeded`) e só entra na exposição com confirmação. Traits em
# GoogleHome::Traits (registro). Estado vai ao Google na hora pelo
# HomeGraph (GoogleHome::HomeGraph, conta de serviço do projeto do dono).
module GoogleHome
  class Error < StandardError
    attr_reader :code

    def initialize(code, message = code)
      @code = code
      super(message)
    end
  end

  INTENT = "action.devices.".freeze

  module_function

  def exposed?(point) = point.expose.to_h["google"] == true && !point.disabled && Traits.for(point).any?
  def exposed(site) = site.points.includes(:device, :area).where(disabled: false).where("points.expose->>'google' = 'true'").order(:name).select { |p| Traits.for(p).any? }

  def agent_user_id(token) = "#{token.site_id}:#{token.user_id}"

  # Corpo do Google (hash) + token em claro → resposta (hash).
  def handle(body, plain_token)
    token = ApiToken.find_client_token(plain_token, "google")
    raise Error, "authExpired" unless token && !token.user.disabled? && token.site_id

    body = body.to_h.deep_stringify_keys
    ActsAsTenant.with_tenant(token.user.tenant) do
      site = token.site
      role = site.role_for(token.user) or raise Error, "authFailure"
      token.touch_usage!
      Current.user = token.user
      input = Array(body["inputs"]).first.to_h
      payload = case input["intent"].to_s.delete_prefix(INTENT)
      when "SYNC" then sync(site, token)
      when "QUERY" then query(site, input.dig("payload", "devices"))
      when "EXECUTE" then execute(site, role, input.dig("payload", "commands"))
      when "DISCONNECT" then disconnect(token)
      else raise Error, "notSupported"
      end
      payload.nil? ? {} : { "requestId" => body["requestId"], "payload" => payload }
    end
  rescue Error => e
    { "requestId" => body.to_h["requestId"], "payload" => { "errorCode" => e.code } }
  ensure
    Current.user = nil
  end

  def device(point)
    traits = Traits.for(point)
    { "id" => point.id, "type" => traits.first.type(point), "traits" => traits.map(&:trait).uniq, "willReportState" => HomeGraph.configured?(point.site),
      "name" => { "name" => point.alexa_label.truncate(60), "defaultNames" => [ point.name ], "nicknames" => Array(point.aliases).first(5) },
      "roomHint" => point.area&.name, "attributes" => traits.map { |t| t.attributes(point) }.reduce({}, :merge),
      "deviceInfo" => { "manufacturer" => point.device.manufacturer.presence || "Minha Automação", "model" => point.device.model.presence || point.capability }.compact }.compact
  end

  def sync(site, token) = { "agentUserId" => agent_user_id(token), "devices" => exposed(site).map { |p| device(p) } }

  def state(point, value = point.value)
    base = { "online" => point.quality != "unavailable" }
    Traits.for(point).map { |t| t.state(point, value) }.reduce(base, :merge)
  end

  def query(site, devices)
    by_id = exposed(site).index_by(&:id)
    { "devices" => Array(devices).to_h { |d| (p = by_id[d["id"]]) ? [ d["id"], state(p).merge("status" => "SUCCESS") ] : [ d["id"], { "status" => "ERROR", "errorCode" => "deviceNotFound" } ] } }
  end

  def execute(site, role, commands)
    by_id = exposed(site).index_by(&:id)
    results = Array(commands).flat_map do |c|
      Array(c["devices"]).flat_map do |d|
        Array(c["execution"]).map { |ex| run(by_id[d["id"]], d["id"], ex, role) }
      end
    end
    { "commands" => results }
  end

  def run(point, id, ex, role)
    raise Error, "deviceNotFound" unless point
    raise Error, "authFailure" unless SiteMembership.allowed?(role, :command, risk: point.risk)
    raise Error, "deviceOffline" if point.quality == "unavailable"

    command = ex["command"].to_s.delete_prefix(Traits::COMMAND)
    trait = Traits.for(point).find { |t| t.commands.include?(command) } or raise Error, "notSupported"
    # Crítico (portão): o Google pergunta "tem certeza?" antes de mandar.
    return { "ids" => [ id ], "status" => "ERROR", "errorCode" => "challengeNeeded", "challengeNeeded" => { "type" => "ackNeeded" } } if point.risk == "critical" && ex.dig("challenge", "ack") != true

    cmd, arg, target = trait.execute(command, ex["params"].to_h, point)
    expected = point.value
    if cmd
      target ||= point
      expected = Points::Command.new(target, cmd, arg).new_value if target == point
      c = Points::Command.call(target, cmd, arg, source: "google", user: Current.user)
      raise Error, "deviceTurnedOff" if c.status == "failed"
    end
    { "ids" => [ id ], "status" => "SUCCESS", "states" => state(point, expected) }
  rescue Points::Command::Error
    { "ids" => [ id ], "status" => "ERROR", "errorCode" => "valueOutOfRange" }
  rescue Error => e
    { "ids" => [ id ], "status" => "ERROR", "errorCode" => e.code }
  end

  def disconnect(token)
    ApiToken.active.where(client: "google", site_id: token.site_id, user_id: token.user_id).find_each(&:revoke!)
    nil
  end
end
