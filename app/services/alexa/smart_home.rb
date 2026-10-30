module Alexa
  # Skill Smart Home v3 (F9): a Lambda da AWS só repassa a diretiva para
  # POST /alexa/smart_home; aqui ela é atendida. O token (do account linking,
  # `ApiToken` de cliente "alexa") diz a pessoa e o local. Só entra o que está
  # marcado "Expor para a Alexa" (ponto ou cena); o comando sai pelo
  # Points::Command com o papel da pessoa x risco, `source: "alexa"`.
  # Interface por capacidade: Alexa::SmartHome::Interfaces (registro).
  module SmartHome
    class Error < StandardError
      attr_reader :type

      def initialize(type, message)
        @type = type
        super(message)
      end
    end

    SCENE_PREFIX = "scene-".freeze

    module_function

    # Diretiva (hash) → resposta (hash). Erro vira ErrorResponse.
    def handle(body)
      directive = body.to_h.deep_stringify_keys["directive"] or raise Error.new("INVALID_DIRECTIVE", "Sem diretiva.")
      header = directive["header"].to_h
      return accept_grant(header) if header["namespace"] == "Alexa.Authorization"

      token = token!(directive)
      ActsAsTenant.with_tenant(token.user.tenant) do
        site = token.site
        role = site.role_for(token.user) or raise Error.new("INVALID_AUTHORIZATION_CREDENTIAL", "Sem acesso ao local.")
        token.touch_usage!
        Current.user = token.user
        return discover(header, site) if header["namespace"] == "Alexa.Discovery"

        target = find_target(site, directive.dig("endpoint", "endpointId"))
        return state_report(header, directive, target) if header["namespace"] == "Alexa" && header["name"] == "ReportState"

        control(header, directive, target, role)
      end
    rescue Error => e
      error_response(header || {}, directive || {}, e)
    ensure
      Current.user = nil
    end

    def token!(directive)
      plain = directive.dig("payload", "scope", "token") || directive.dig("endpoint", "scope", "token")
      token = ApiToken.find_alexa(plain)
      raise Error.new("INVALID_AUTHORIZATION_CREDENTIAL", "Token inválido ou vencido.") unless token && !token.user.disabled? && token.site_id

      token
    end

    # O que está exposto e tem ao menos uma interface.
    def exposed(site)
      points = site.points.includes(:device, :area).where(alexa_exposed: true, disabled: false).order(:name).to_a
      [ *points, *site.scenes.where(alexa_exposed: true).order(:name) ].filter_map { |t| [ t, Interfaces.for(t) ] if Interfaces.for(t).any? }
    end

    def endpoint_id(t) = t.is_a?(Scene) ? "#{SCENE_PREFIX}#{t.id}" : t.id

    def find_target(site, id)
      t = id.to_s.start_with?(SCENE_PREFIX) ? site.scenes.find_by(id: id.delete_prefix(SCENE_PREFIX)) : site.points.find_by(id: id)
      raise Error.new("NO_SUCH_ENDPOINT", "Não existe ou não está exposto.") unless t&.alexa_exposed && (!t.is_a?(Point) || !t.disabled)

      t
    end

    def discover(header, site)
      endpoints = exposed(site).map do |t, ifaces|
        caps = [ { "type" => "AlexaInterface", "interface" => "Alexa", "version" => "3" }, *ifaces.map { |i| i.capability(t) } ]
        caps << { "type" => "AlexaInterface", "interface" => "Alexa.EndpointHealth", "version" => "3", "properties" => Interfaces::Base.props("connectivity") } if t.is_a?(Point)
        { "endpointId" => endpoint_id(t), "manufacturerName" => "Minha Automação", "friendlyName" => t.alexa_label.truncate(128),
          "description" => (t.is_a?(Scene) ? "Cena" : "#{t.capability_label} · #{t.device.name}").truncate(128),
          "displayCategories" => [ ifaces.first.category_for(t) ], "cookie" => {}, "capabilities" => caps }
      end
      { "event" => { "header" => out_header(header, "Alexa.Discovery", "Discover.Response"), "payload" => { "endpoints" => endpoints } } }
    end

    def state_report(header, directive, target)
      { "event" => { "header" => out_header(header, "Alexa", "StateReport"), "endpoint" => directive["endpoint"], "payload" => {} },
        "context" => { "properties" => properties(target) } }
    end

    # Diretiva de controle: a interface traduz; o comando passa pelo papel x risco.
    def control(header, directive, target, role)
      iface = Interfaces[header["namespace"]]
      raise Error.new("INVALID_DIRECTIVE", "Interface não suportada: #{header['namespace']}.") unless iface&.applies?(target)

      command, value = iface.handle(header["name"], directive["payload"].to_h, target)
      return scene(header, directive, target, role) if command == :activate

      risk = target.risk
      raise Error.new("INSUFFICIENT_PERMISSIONS", "Seu papel não permite.") unless SiteMembership.allowed?(role, :command, risk: risk)
      raise Error.new("ENDPOINT_UNREACHABLE", "#{target.name} está sem conexão.") if target.quality == "unavailable"

      expected = command ? run(target, command, value) : value
      { "event" => { "header" => out_header(header, "Alexa", "Response"), "endpoint" => directive["endpoint"], "payload" => {} },
        "context" => { "properties" => properties(target, expected) } }
    end

    def run(point, command, value)
      cmd = Points::Command.new(point, command, value)
      expected = cmd.new_value
      c = Points::Command.call(point, command, value, source: "alexa", user: Current.user)
      raise Error.new("ENDPOINT_UNREACHABLE", c.error.to_s) if c.status == "failed"

      expected
    rescue Points::Command::Error => e
      raise Error.new("INVALID_VALUE", e.message)
    end

    def scene(header, directive, target, role)
      risk = target.risk # cena: o maior dos pontos; script: o ponto já leva o risco do que comanda
      raise Error.new("INSUFFICIENT_PERMISSIONS", "Seu papel não permite.") unless SiteMembership.allowed?(role, :command, risk: risk)

      if target.is_a?(Scene)
        target.activate!(source: "alexa", user: Current.user)
      else
        run(target, "run", nil)
      end
      { "event" => { "header" => out_header(header, "Alexa.SceneController", "ActivationStarted"), "endpoint" => directive["endpoint"],
                     "payload" => { "cause" => { "type" => "VOICE_INTERACTION" }, "timestamp" => now } },
        "context" => {} }
    end

    def properties(target, value = target.try(:value))
      return [] unless target.is_a?(Point)

      list = Interfaces.for(target).flat_map do |i|
        i.properties(target, value).map do |name, v, instance|
          { "namespace" => i.namespace, "name" => name, "value" => v, "timeOfSample" => now, "uncertaintyInMilliseconds" => 500, "instance" => instance }.compact
        end
      end
      list << { "namespace" => "Alexa.EndpointHealth", "name" => "connectivity", "value" => { "value" => target.quality == "unavailable" ? "UNREACHABLE" : "OK" },
                "timeOfSample" => now, "uncertaintyInMilliseconds" => 0 }
    end

    def accept_grant(header)
      { "event" => { "header" => out_header(header, "Alexa.Authorization", "AcceptGrant.Response"), "payload" => {} } }
    end

    def error_response(header, directive, e)
      { "event" => { "header" => out_header(header, "Alexa", "ErrorResponse"), "endpoint" => directive["endpoint"],
                     "payload" => { "type" => e.type, "message" => e.message } }.compact }
    end

    def out_header(header, namespace, name)
      { "namespace" => namespace, "name" => name, "payloadVersion" => "3", "messageId" => SecureRandom.uuid,
        "correlationToken" => header["correlationToken"] }.compact
    end

    def now = Time.current.utc.iso8601
  end
end
