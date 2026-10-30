require "net/http"

module Blueprints
  # Importa blueprint do Home Assistant (YAML colado ou URL do GitHub, gist
  # ou da comunidade) e converte o que a DSL daqui suporta:
  #   entradas com selector entity/target/number/boolean/select/text/time/duration;
  #   gatilhos state/numeric_state/time/sun; condições state/numeric_state/time;
  #   ações light/switch/fan/input_boolean/homeassistant turn_on/turn_off/toggle,
  #   notify.*, persistent_notification.create e delay.
  # O resto entra em `unsupported` ("ação wait_for_trigger"), mostrado na tela;
  # nada levanta erro além de YAML inválido ou "não é blueprint".
  #
  # Lote 4 (G32): também automações e scripts do HA (`automations.yaml`, uma
  # automação só ou `scripts.yaml`). Cada um vira um blueprint deste local em
  # que cada entidade fixa (`entity_id`) é uma entrada de ponto: o "Criar
  # automação" pergunta qual ponto daqui faz o papel de cada entidade, e o
  # relatório do que não converteu é o mesmo `unsupported`.
  class HaImport
    class Error < StandardError; end

    HOSTS = %w[github.com raw.githubusercontent.com gist.github.com gist.githubusercontent.com community.home-assistant.io].freeze
    MAX_BYTES = 200_000
    SWITCHES = %w[light switch fan input_boolean homeassistant].freeze
    COMMANDS = { "turn_on" => "on", "turn_off" => "off", "toggle" => "toggle" }.freeze
    WEEKDAYS = %w[sun mon tue wed thu fri sat].freeze
    IGNORED = %w[alias id description enabled continue_on_error].freeze

    # ---- busca ------------------------------------------------------------------

    def self.fetch(url)
      uri = URI.parse(url.to_s.strip)
      raise Error, "Use um endereço https do GitHub, gist ou da comunidade do Home Assistant." unless uri.is_a?(URI::HTTPS) && HOSTS.include?(uri.host)

      community = uri.host == "community.home-assistant.io"
      body = get(raw_uri(uri))
      community ? community_yaml(body) : body
    rescue URI::InvalidURIError
      raise Error, "Endereço inválido."
    end

    # Página do GitHub/gist → texto puro; tópico da comunidade → JSON do tópico.
    def self.raw_uri(uri)
      parts = uri.path.split("/")
      if uri.host == "github.com" && parts[3] == "blob"
        URI("https://raw.githubusercontent.com/#{parts[1]}/#{parts[2]}/#{parts[4..].join('/')}")
      elsif uri.host == "gist.github.com"
        URI("https://gist.githubusercontent.com#{uri.path.chomp('/')}/raw")
      elsif uri.host == "community.home-assistant.io" && (id = uri.path[%r{/t/(?:[^/]+/)?(\d+)}, 1])
        URI("https://community.home-assistant.io/t/#{id}.json")
      else
        uri
      end
    end

    def self.get(uri, hops = 3)
      raise Error, "Endereço fora dos permitidos." unless uri.is_a?(URI::HTTPS) && HOSTS.include?(uri.host)

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) { |http| http.get(uri.request_uri) }
      return get(URI(res["location"]), hops - 1) if res.is_a?(Net::HTTPRedirection) && hops.positive?
      raise Error, "O endereço respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)
      raise Error, "Arquivo grande demais." if res.body.to_s.bytesize > MAX_BYTES

      res.body.to_s.force_encoding("UTF-8")
    rescue SocketError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error, "Não consegui baixar: #{e.message.truncate(80)}"
    end

    # Primeiro bloco de código com "blueprint:" do primeiro post.
    def self.community_yaml(json)
      cooked = JSON.parse(json).dig("post_stream", "posts", 0, "cooked").to_s
      code = cooked.scan(%r{<code[^>]*>(.*?)</code>}m).flatten.find { |c| c.include?("blueprint:") }
      raise Error, "Não achei o YAML do blueprint no tópico." unless code

      CGI.unescapeHTML(code)
    rescue JSON::ParserError
      raise Error, "Resposta da comunidade inválida."
    end

    # ---- conversão --------------------------------------------------------------

    def self.call(text, source_url: nil) = new(text, source_url).call

    ENTITY = /\A[a-z_]+\.[a-z0-9_]+\z/
    MAX_ITEMS = 100

    # Blueprint, automação(ões) ou scripts do HA → lista de atributos de Blueprint.
    def self.import(text, source_url: nil)
      importer = new(text, source_url)
      doc = importer.send(:parse)
      return [ importer.call ] if doc.is_a?(Hash) && doc.key?("blueprint")

      items = ha_items(doc)
      raise Error, "Não achei blueprint, automação nem script do Home Assistant no YAML." if items.empty?
      raise Error, "Itens demais (máximo #{MAX_ITEMS} por vez)." if items.size > MAX_ITEMS

      items.map { |domain, name, body| new("", source_url).convert(as_blueprint(domain, name, body)) }
    end

    # [[domínio, nome, corpo]]: lista de automações, uma automação ou o mapa de scripts.
    def self.ha_items(doc)
      automation = ->(h) { h.is_a?(Hash) && (h.key?("trigger") || h.key?("triggers")) && (h.key?("action") || h.key?("actions")) }
      if doc.is_a?(Array) then doc.select(&automation).each_with_index.map { |a, i| [ "automation", a["alias"].presence || "Automação #{i + 1}", a ] }
      elsif automation.call(doc) then [ [ "automation", doc["alias"].presence || "Automação importada", doc ] ]
      elsif doc.is_a?(Hash) then doc.select { |_, s| s.is_a?(Hash) && s.key?("sequence") }.map { |k, s| [ "script", s["alias"].presence || k.to_s.humanize, s ] }
      else []
      end
    end

    # Entidade fixa → entrada `!input` de ponto (filtrada pelo domínio da entidade).
    def self.as_blueprint(domain, name, body)
      inputs = {}
      walk = lambda do |v, key = nil|
        if key == "entity_id" && (v.is_a?(String) || v.is_a?(Array))
          refs = Array(v).map do |e|
            next e unless e.is_a?(String) && e.match?(ENTITY)

            k = e.tr(".", "_").first(60)
            inputs[k] ||= { "name" => e, "selector" => { "entity" => { "domain" => e.split(".").first } } }
            { "!input" => k }
          end
          v.is_a?(Array) ? refs : refs.first
        elsif v.is_a?(Hash) then v.to_h { |k, x| [ k, walk.call(x, k) ] }
        elsif v.is_a?(Array) then v.map { |x| walk.call(x) }
        else v
        end
      end
      converted = walk.call(body.except("id", "alias", "description", "icon", "fields"))
      converted.merge("blueprint" => { "name" => name.to_s.truncate(120), "description" => body["description"].to_s.presence, "domain" => domain, "input" => inputs })
    end

    def initialize(text, source_url = nil)
      @text = text.to_s
      @source_url = source_url
      @unsupported = []
      @inputs = {}
    end

    # → atributos do Blueprint (com `unsupported`).
    def call
      doc = parse
      raise Error, "O YAML precisa ser um objeto." unless doc.is_a?(Hash)

      convert(doc)
    end

    def convert(doc)
      bp = doc["blueprint"]
      raise Error, "Não parece um blueprint do Home Assistant (falta a chave blueprint)." unless bp.is_a?(Hash)

      domain = bp["domain"].to_s
      raise Error, "Domínio \"#{domain}\" não suportado (só automation e script)." unless %w[automation script].include?(domain)

      convert_inputs(bp["input"])
      definition = domain == "script" ? { "actions" => actions(doc["sequence"]) } : automation(doc)
      (doc.keys - %w[blueprint mode max max_exceeded trigger triggers condition conditions action actions sequence fields description alias icon]).each { |k| note("chave #{k}") }
      mode = doc["mode"].to_s.presence_in(Automation::MODES.keys) || "single"
      { "name" => bp["name"].to_s.presence || "Blueprint importado", "description" => bp["description"].to_s.truncate(1000).presence,
        "domain" => domain, "mode" => mode, "inputs" => @inputs.values, "definition" => definition, "source" => "ha",
        "source_url" => (bp["source_url"].presence || @source_url).to_s.truncate(500).presence, "unsupported" => @unsupported.uniq }
    end

    private

    # `!input nome` vira `{"!input": "nome"}` antes do YAML seguro.
    def parse
      raise Error, "Cole o YAML do blueprint." if @text.strip.empty?
      raise Error, "YAML grande demais." if @text.bytesize > MAX_BYTES

      yaml = @text.gsub(/!input\s+(['"]?)([\w.-]+)\1/) { %({"!input": "#{::Regexp.last_match(2)}"}) }
      YAML.safe_load(yaml, aliases: false)
    rescue Psych::Exception => e
      raise Error, "YAML inválido: #{e.message.truncate(120)}"
    end

    def note(what) = @unsupported << what

    def automation(doc)
      { "triggers" => list(doc["triggers"] || doc["trigger"]).filter_map { |t| trigger(t) },
        "conditions" => list(doc["conditions"] || doc["condition"]).filter_map { |c| condition(c) },
        "actions" => actions(doc["actions"] || doc["action"]) }
    end

    def list(v) = v.nil? ? [] : Array.wrap(v)

    # ---- entradas ---------------------------------------------------------------

    def convert_inputs(raw)
      return unless raw.is_a?(Hash)

      raw.each do |key, spec|
        next convert_inputs(spec["input"]) if spec.is_a?(Hash) && spec["input"].is_a?(Hash) # seção (HA 2024.6+)

        input(key.to_s, spec.is_a?(Hash) ? spec : {})
      end
    end

    def input(key, spec)
      selector = spec["selector"].is_a?(Hash) ? spec["selector"] : {}
      kind, conf = selector.first
      conf = {} unless conf.is_a?(Hash)
      base = { "key" => key.downcase.gsub(/[^a-z0-9_]/, "_"), "label" => spec["name"].to_s.presence || key.to_s.humanize,
               "description" => spec["description"].to_s.truncate(300).presence }.compact
      typed = input_type(kind.to_s, conf, key)
      return note("entrada #{key} (selector #{kind || 'sem tipo'})") unless typed

      default = input_default(typed["type"], spec["default"])
      @inputs[key] = base.merge(typed).merge(spec.key?("default") && !default.nil? ? { "default" => default } : {})
      @inputs[key]["required"] = false if spec.key?("default") && default.nil?
    end

    def input_type(kind, conf, key)
      case kind
      when "entity" then point_input(conf, key)
      when "target" then point_input(conf["entity"].is_a?(Hash) ? conf["entity"] : {}, key)
      when "number" then { "type" => "number" }
      when "boolean" then { "type" => "boolean" }
      when "text" then { "type" => "text" }
      when "time" then { "type" => "time" }
      when "duration" then { "type" => "duration" }
      when "select"
        options = Array(conf["options"]).map { |o| o.is_a?(Hash) ? o["value"].to_s : o.to_s }.compact_blank
        options.any? ? { "type" => "select", "options" => options } : nil
      end
    end

    # Domínio/classe do HA → capacidades daqui.
    def point_input(conf, key)
      filters = conf["filter"] ? Array.wrap(conf["filter"]) : [ conf ]
      note("entrada #{key}: várias entidades (aqui é um ponto só)") if conf["multiple"]
      caps = filters.flat_map { |f| capabilities(Array(f["domain"]), Array(f["device_class"])) }.uniq
      writable = filters.any? && filters.all? { |f| (Array(f["domain"]) & SWITCHES).any? }
      filter = { "capability" => caps.presence, "writable" => (true if writable) }.compact
      { "type" => "point", "filter" => filter.presence }.compact
    end

    def capabilities(domains, classes)
      domains.flat_map do |d|
        case d
        when "light", "switch", "fan", "input_boolean" then %w[onoff]
        when "sensor" then %w[measure]
        when "binary_sensor"
          next %w[motion] if (classes & %w[motion occupancy presence]).any?
          next %w[contact] if (classes & %w[door window opening garage_door]).any?

          %w[contact motion problem tamper]
        else []
        end
      end
    end

    def input_default(type, v)
      return nil if v.nil?

      case type
      when "duration" then duration(v)
      when "time" then v.to_s[0, 5]
      when "point" then nil
      else v
      end
    end

    # ---- gatilhos e condições ---------------------------------------------------

    def trigger(t)
      return note("gatilho inválido") unless t.is_a?(Hash)

      kind = (t["trigger"] || t["platform"]).to_s
      out = case kind
      when "state" then state_like(t, "to", "from")&.merge({ "type" => "state" })
      when "numeric_state" then numeric(t)
      when "time"
        at = t["at"].is_a?(Array) ? (note("gatilho time com vários horários: usei o primeiro") && t["at"].first) : t["at"]
        at = at.is_a?(String) ? at[0, 5] : at
        input_ref?(at) || at.to_s.match?(Automations::Dsl::TIME) ? { "type" => "time", "at" => at } : note("gatilho time por entidade") && nil
      when "sun" then { "type" => "sun", "event" => t["event"].to_s, "offset" => (duration(t["offset"]) if t["offset"]) }.compact
      when "time_pattern" then time_pattern(t)
      when "webhook" then { "type" => "webhook" }
      when "event" then event_trigger(t)
      end
      out || (note("gatilho #{kind.presence || '?'}") && nil)
    end

    # Lote 4 (G32): "/N" em minutos (ou horas) vira "a cada"; o resto não converte.
    def time_pattern(t)
      return { "type" => "time", "every" => "#{t['minutes'].to_s.delete_prefix('/')}m" } if t["minutes"].to_s.match?(%r{\A/\d+\z}) && t["hours"].blank?
      return { "type" => "time", "every" => "#{t['hours'].to_s.delete_prefix('/')}h" } if t["hours"].to_s.match?(%r{\A/\d+\z}) && t["minutes"].to_s.in?(%w[0 00])

      nil
    end

    # Evento com nome (G6): os dados do filtro só os que são texto simples.
    def event_trigger(t)
      name = t["event_type"].to_s
      return unless name.match?(Automations::Triggers::EVENT_NAME)

      data = t["event_data"].is_a?(Hash) ? t["event_data"].select { |_, v| v.is_a?(String) || v.is_a?(Numeric) }.transform_values(&:to_s) : {}
      { "type" => "event", "event" => name, "match" => data.presence }.compact
    end

    def condition(c)
      return note("condição em texto (template)") && nil unless c.is_a?(Hash)

      kind = c["condition"].to_s
      out = case kind
      when "state" then state_like(c, "state", nil)&.then { |h| h.transform_keys { |k| k == "state" ? "is" : k } }&.merge({ "type" => "state" })
      when "numeric_state" then numeric(c)&.except("for")
      when "time"
        days = Array(c["weekday"]).filter_map { |d| WEEKDAYS.index(d.to_s) }
        { "type" => "time", "after" => c["after"]&.to_s&.first(5), "before" => c["before"]&.to_s&.first(5), "days" => days.presence }.compact
      end
      out || (note("condição #{kind.presence || '?'}") && nil)
    end

    def state_like(h, to_key, from_key)
      point = entity(h["entity_id"]) or return
      note("estado de atributo (#{h['attribute']})") if h["attribute"]
      out = { "point" => point }
      out[to_key] = state_value(h[to_key]) if h.key?(to_key) && !h[to_key].is_a?(Array)
      out[from_key] = state_value(h[from_key]) if from_key && h.key?(from_key) && !h[from_key].is_a?(Array)
      out["for"] = duration(h["for"]) if h["for"]
      out.compact
    end

    def numeric(h)
      point = entity(h["entity_id"]) or return
      { "type" => "numeric", "point" => point, "above" => h["above"], "below" => h["below"], "for" => (duration(h["for"]) if h["for"]) }.compact
    end

    # "on"/"off" do HA → liga/desliga daqui; o resto como veio.
    def state_value(v)
      return v if input_ref?(v)

      { "on" => true, "off" => false }.fetch(v.to_s, v&.to_s)
    end

    # ---- ações ------------------------------------------------------------------

    def actions(raw) = list(raw).flat_map { |a| action(a) }

    # Controle de fluxo do HA → blocos da DSL (Lote 4, G32): chave do HA → método.
    FLOW = { "if" => :flow_if, "choose" => :flow_choose, "condition" => :flow_condition, "stop" => :flow_stop,
             "repeat" => :flow_repeat, "variables" => :flow_variables }.freeze

    def action(a)
      return note("ação em texto") && [] unless a.is_a?(Hash)
      return [ { "type" => "wait", "for" => duration(a["delay"]) } ] if a.key?("delay")

      flow = FLOW.find { |k, _| a.key?(k) }
      return send(flow[1], a) if flow

      service = (a["action"] || a["service"]).to_s
      return note("ação #{(a.keys - IGNORED).first || '?'}") && [] if service.empty?

      domain, name = service.split(".", 2)
      if SWITCHES.include?(domain) && COMMANDS.key?(name)
        note("dados extras em #{service} (brilho, cor...)") if a["data"].is_a?(Hash) && (a["data"].keys - %w[entity_id]).any?
        targets(a).map { |p| { "type" => "command", "point" => p, "command" => COMMANDS[name] } }
      elsif domain == "notify" || service == "persistent_notification.create"
        data = a["data"].is_a?(Hash) ? a["data"] : {}
        [ notify(data, domain == "notify" ? %w[in_app push] : %w[in_app]) ]
      else
        note("ação #{service}") && []
      end
    end

    def conditions(raw)
      given = list(raw)
      out = given.filter_map { |c| condition(c) }
      note("condição não convertida dentro de se/escolher/repetir: o bloco ficou sem ela, confira") if out.size < given.size
      out
    end

    def flow_if(a)
      [ { "type" => "if", "conditions" => conditions(a["if"]), "then" => actions(a["then"]), "else" => actions(a["else"]).presence }.compact ]
    end

    def flow_choose(a)
      options = list(a["choose"]).map { |o| { "conditions" => conditions(o["conditions"]), "actions" => actions(o["sequence"]) } }
      return note("ação choose") && [] if options.empty?

      [ { "type" => "choose", "options" => options, "default" => actions(a["default"]).presence }.compact ]
    end

    def flow_condition(a) = [ { "type" => "condition", "conditions" => conditions([ a ]) } ]
    def flow_stop(a) = [ { "type" => "stop", "reason" => a["stop"].to_s.presence, "error" => (true if a["error"] == true) }.compact ]

    def flow_repeat(a)
      r = a["repeat"].is_a?(Hash) ? a["repeat"] : {}
      body = { "type" => "repeat", "actions" => actions(r["sequence"]) }
      return [ body.merge("count" => r["count"]) ] if r["count"].is_a?(Integer)
      return [ body.merge("while" => conditions(r["while"])) ] if r.key?("while")
      return [ body.merge("until" => conditions(r["until"])) ] if r.key?("until")

      note("repetição #{(r.keys - %w[sequence]).first || '?'} (for_each)") && []
    end

    def flow_variables(a)
      vars = a["variables"].is_a?(Hash) ? a["variables"] : {}
      note("variáveis com template do HA (confira o texto)") if vars.values.any? { |v| v.to_s.include?("{{") || v.to_s.include?("{%") }
      vars.map { |k, v| { "type" => "set", "var" => k.to_s.downcase.gsub(/[^a-z0-9_]/, "_"), "value" => v.to_s } }
    end

    def targets(a)
      raw = a.key?("target") ? a["target"] : (a["entity_id"] || a.dig("data", "entity_id"))
      raw = raw["entity_id"] if raw.is_a?(Hash) && !input_ref?(raw)
      Array.wrap(raw).filter_map { |e| entity(e) }
    end

    def notify(data, channels)
      title = data["title"].to_s.presence || "Aviso"
      message = data["message"].to_s.presence
      note("texto com template do HA no aviso (confira: as variáveis do HA não existem aqui)") if [ title, message ].compact.any? { |t| t.include?("{{") || t.include?("{%") }
      { "type" => "notify", "channels" => channels, "title" => title.truncate(500), "message" => message&.truncate(500) }.compact
    end

    # ---- valores ----------------------------------------------------------------

    # Entidade: só pela entrada (ponto escolhido ao criar a automação).
    def entity(v)
      v = v.first if v.is_a?(Array) && v.size == 1
      return v if input_ref?(v) && @inputs.dig(v["!input"], "type") == "point"

      note(v.is_a?(String) ? "entidade fixa #{v} (use uma entrada de ponto)" : "entidade #{v.inspect.truncate(60)}")
      nil
    end

    def input_ref?(v) = v.is_a?(Hash) && v.keys == [ "!input" ]

    # "00:05:00", {minutes: 5}, 300 ou entrada → "5m" / segundos.
    def duration(v)
      return v if input_ref?(v)

      m = v.is_a?(String) && v.match(/\A(-)?(\d+):(\d{2})(?::(\d{2}))?/)
      sec = if v.is_a?(Numeric) then v.to_i
      elsif v.is_a?(Hash) then (v["days"].to_i * 86_400) + (v["hours"].to_i * 3600) + (v["minutes"].to_i * 60) + v["seconds"].to_i
      elsif m then (m[1] ? -1 : 1) * ((m[2].to_i * 3600) + (m[3].to_i * 60) + m[4].to_i)
      else return note("duração #{v.inspect.truncate(40)}") && nil
      end
      sign = sec.negative? ? "-" : ""
      h, rest = sec.abs.divmod(3600)
      min, s = rest.divmod(60)
      "#{sign}#{"#{h}h" if h.positive?}#{"#{min}m" if min.positive?}#{"#{s}s" if s.positive? || sec.zero?}"
    end
  end
end
