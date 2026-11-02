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
  #
  # Lote 5: aparelho (`device_id` e gatilho/condição/ação `device`), início do
  # HA (evento "system_started"), horário vindo de entidade (`at_point`),
  # agenda, cena (entrada do tipo cena), script (ponto `script`, comando run),
  # espelho `turn_{{ trigger.to_state.state }}`, helpers (set/select/start...),
  # evento, espera de evento ou de template, agenda, previsão e IA; o `id` do
  # gatilho vai junto e a condição `trigger` vira `trigger.id = 'x'`. O Jinja
  # comum vira expressão ou Liquid (Blueprints::Jinja); a entidade citada no
  # texto vira entrada e aparece como `[[entrada]]`.
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
      raise Error, I18n.t("automations.ha_import.https_only") unless uri.is_a?(URI::HTTPS) && HOSTS.include?(uri.host)

      community = uri.host == "community.home-assistant.io"
      body = get(raw_uri(uri))
      community ? community_yaml(body) : body
    rescue URI::InvalidURIError
      raise Error, I18n.t("automations.ha_import.bad_url")
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
      raise Error, I18n.t("automations.ha_import.host_not_allowed") unless uri.is_a?(URI::HTTPS) && HOSTS.include?(uri.host)

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) { |http| http.get(uri.request_uri) }
      return get(URI(res["location"]), hops - 1) if res.is_a?(Net::HTTPRedirection) && hops.positive?
      raise Error, I18n.t("automations.ha_import.http_status", code: res.code) unless res.is_a?(Net::HTTPSuccess)
      raise Error, I18n.t("automations.ha_import.file_too_big") if res.body.to_s.bytesize > MAX_BYTES

      res.body.to_s.force_encoding("UTF-8")
    rescue SocketError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error, I18n.t("automations.ha_import.download_failed", error: e.message.truncate(80))
    end

    # Primeiro bloco de código com "blueprint:" do primeiro post.
    def self.community_yaml(json)
      cooked = JSON.parse(json).dig("post_stream", "posts", 0, "cooked").to_s
      code = cooked.scan(%r{<code[^>]*>(.*?)</code>}m).flatten.find { |c| c.include?("blueprint:") }
      raise Error, I18n.t("automations.ha_import.no_yaml_in_topic") unless code

      CGI.unescapeHTML(code)
    rescue JSON::ParserError
      raise Error, I18n.t("automations.ha_import.bad_community")
    end

    # ---- conversão --------------------------------------------------------------

    def self.call(text, source_url: nil) = new(text, source_url).call

    ENTITY = /\A[a-z_]+\.[a-z0-9_]+\z/
    DEVICE = /\A[0-9a-f]{32}\z/
    MAX_ITEMS = 100
    # Domínios do HA sem ponto equivalente aqui (não viram entrada no texto).
    NO_POINT = %w[sun zone person device_tracker update conversation ai_task tts stt automation].freeze
    # Lote 7: integração do HA (domínio) → plugin daqui (recarregar, `integration_ok`)
    # e → driver dos aparelhos daqui (consulta `integration=`). Dado sobre o HA, não sobre a casa.
    HA_PLUGINS = { "tuya" => "tuya", "localtuya" => "tuya", "alexa_media" => "alexa", "xiaomi_home" => "xiaomi", "xiaomi_miot" => "xiaomi",
                   "google" => "calendar", "met" => "weather", "mqtt" => "mqtt" }.freeze
    HA_DRIVERS = { "tuya" => "tuya_cloud", "localtuya" => "tuya_local", "alexa_media" => "alexa", "xiaomi_home" => "xiaomi_miot",
                   "xiaomi_miot" => "xiaomi_miot", "mqtt" => "mqtt" }.freeze
    # Ações do HA que só anotam no diário → "Anotar" (fica no trace).
    LOG_SERVICES = %w[logbook.log system_log.write].freeze
    # Serviço do aspirador do HA → comando do ponto aspirador daqui (Points::Command).
    VACUUM_COMMANDS = { "start" => "start", "pause" => "pause", "stop" => "stop", "return_to_base" => "home", "locate" => "locate" }.freeze

    # Blueprint, automação(ões) ou scripts do HA → lista de atributos de Blueprint.
    def self.import(text, source_url: nil)
      importer = new(text, source_url)
      doc = importer.send(:parse)
      return [ importer.call ] if doc.is_a?(Hash) && doc.key?("blueprint")

      items = ha_items(doc)
      raise Error, I18n.t("automations.ha_import.nothing_found") if items.empty?
      raise Error, I18n.t("automations.ha_import.too_many", max: MAX_ITEMS) if items.size > MAX_ITEMS

      items.map { |domain, name, body| new("", source_url, entities: true).convert(as_blueprint(domain, name, body)) }
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
    # Lote 5: aparelho (`device_id`, ou o `entity_id` do registro, que é um id
    # de 32 hex) também vira entrada, com o domínio do bloco como filtro; no
    # gatilho, condição e ação de aparelho fica só a entidade.
    def self.as_blueprint(domain, name, body)
      inputs = {}
      ref = lambda do |e, hint|
        if e.match?(ENTITY)
          k = e.tr(".", "_").first(60)
          inputs[k] ||= { "name" => e, "selector" => { "entity" => { "domain" => e.split(".").first } } }
        elsif e.match?(DEVICE)
          k = "aparelho_#{e.first(8)}"
          inputs[k] ||= { "name" => "Aparelho do HA #{e.first(8)}#{" (#{hint})" if hint}", "selector" => { "entity" => { "domain" => hint }.compact } }
        else next e
        end
        { "!input" => k }
      end
      walk = lambda do |v, hint = nil|
        if v.is_a?(Hash)
          hint = v["domain"].presence || (v["action"] || v["service"]).to_s.split(".").first.presence || hint
          v = v.except("device_id") if v["type"] && v["entity_id"].present?
          v.to_h do |k, x|
            next [ k, walk.call(x, hint) ] unless %w[entity_id device_id].include?(k) && (x.is_a?(String) || x.is_a?(Array))

            refs = Array(x).map { |e| e.is_a?(String) ? ref.call(e, hint) : e }
            [ k, x.is_a?(Array) ? refs : refs.first ]
          end
        elsif v.is_a?(Array) then v.map { |x| walk.call(x, hint) }
        else v
        end
      end
      converted = walk.call(body.except("id", "alias", "description", "icon", "fields"))
      converted.merge("blueprint" => { "name" => name.to_s.truncate(120), "description" => body["description"].to_s.presence, "domain" => domain, "input" => inputs })
    end

    # `entities`: entidade fixa citada em texto ou horário vira entrada (só nas
    # automações e scripts do HA; num blueprint de verdade fica anotada).
    # Lote 7 (opcionais, do importador da instalação): `areas`/`labels` (id do
    # HA → nome daqui), `entries` (id da integração do HA → domínio) e
    # `rest_commands` (o `rest_command:` do configuration.yaml).
    def initialize(text, source_url = nil, entities: false, areas: {}, labels: {}, entries: {}, rest_commands: {})
      @entities = entities
      @text = text.to_s
      @source_url = source_url
      @unsupported = []
      @inputs = {}
      @entries = entries.to_h
      @rest = rest_commands.to_h
      @areas = areas.to_h
      @labels = labels.to_h
      @consts = {}
      @jinja = Jinja.new(method(:entity_input), areas: areas.to_h, labels: labels.to_h, entries: @entries)
    end

    # → atributos do Blueprint (com `unsupported`).
    def call
      doc = parse
      raise Error, I18n.t("automations.ha_import.not_object") unless doc.is_a?(Hash)

      convert(doc)
    end

    def convert(doc)
      bp = doc["blueprint"]
      raise Error, I18n.t("automations.ha_import.not_blueprint") unless bp.is_a?(Hash)

      domain = bp["domain"].to_s
      raise Error, I18n.t("automations.ha_import.bad_domain", domain: domain) unless %w[automation script].include?(domain)

      convert_inputs(bp["input"])
      @consts = doc["variables"].is_a?(Hash) ? doc["variables"].select { |_, v| v.is_a?(String) && !v.include?("{") }.transform_keys(&:to_s) : {}
      @jinja.consts = @consts
      definition = domain == "script" ? { "actions" => actions(doc["sequence"]) } : automation(doc)
      definition["actions"] = flow_variables(doc) + definition["actions"] if doc["variables"].is_a?(Hash) # variáveis da automação: no começo
      (doc.keys - %w[blueprint mode max max_exceeded trigger triggers condition conditions action actions sequence fields description alias icon
                     variables initial_state trace]).each { |k| note("chave #{k}") }
      mode = doc["mode"].to_s.presence_in(Automation::MODES.keys) || "single"
      { "name" => bp["name"].to_s.presence || "Blueprint importado", "description" => bp["description"].to_s.truncate(1000).presence,
        "domain" => domain, "mode" => mode, "inputs" => @inputs.values, "definition" => definition, "source" => "ha",
        "source_url" => (bp["source_url"].presence || @source_url).to_s.truncate(500).presence, "unsupported" => @unsupported.uniq }
    end

    private

    # `!input nome` vira `{"!input": "nome"}` antes do YAML seguro.
    def parse
      raise Error, I18n.t("automations.ha_import.paste_yaml") if @text.strip.empty?
      raise Error, I18n.t("automations.ha_import.yaml_too_big") if @text.bytesize > MAX_BYTES

      yaml = @text.gsub(/!input\s+(['"]?)([\w.-]+)\1/) { %({"!input": "#{::Regexp.last_match(2)}"}) }
      YAML.safe_load(yaml, aliases: false)
    rescue Psych::Exception => e
      raise Error, "YAML inválido: #{e.message.truncate(120)}"
    end

    def note(what) = @unsupported << what

    def automation(doc)
      { "triggers" => list(doc["triggers"] || doc["trigger"]).flat_map { |t| trigger(t) },
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
      when "entity" then Array(conf["domain"]) == [ "scene" ] ? { "type" => "scene" } : point_input(conf, key)
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

    # Domínio do HA → capacidade daqui (o binary_sensor depende da classe).
    DOMAIN_CAPS = { "light" => "onoff", "switch" => "onoff", "fan" => "onoff", "input_boolean" => "onoff", "sensor" => "measure",
                    "script" => "script", "calendar" => "calendar", "weather" => "weather", "camera" => "stream", "input_text" => "text",
                    "input_select" => "enum", "select" => "enum", "input_datetime" => "datetime", "counter" => "counter", "timer" => "timer",
                    "vacuum" => "vacuum", "media_player" => "speaker" }.freeze

    def capabilities(domains, classes)
      domains.flat_map do |d|
        next Array(DOMAIN_CAPS[d]) unless d == "binary_sensor"
        next %w[motion] if (classes & %w[motion occupancy presence]).any?
        next %w[contact] if (classes & %w[door window opening garage_door]).any?

        %w[contact motion problem tamper]
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

    # Entidade citada num texto Jinja ou num horário (Lote 5) → chave da
    # entrada de ponto (nil = domínio sem ponto aqui).
    def entity_input(e)
      domain = e.split(".").first
      return if !@entities || NO_POINT.include?(domain)

      k = e.tr(".", "_").first(60)
      input(k, { "name" => e, "selector" => { "entity" => { "domain" => domain } } }) unless @inputs.key?(k)
      k if @inputs.dig(k, "type") == "point"
    end

    # ---- gatilhos e condições ---------------------------------------------------

    # Gatilho do HA → lista de gatilhos daqui (vários horários ou entidades viram um cada).
    def trigger(t)
      return note("gatilho inválido") && [] unless t.is_a?(Hash)

      ids = t["entity_id"]
      return ids.flat_map { |e| trigger(t.merge("entity_id" => e)) } if ids.is_a?(Array) && ids.size > 1

      kind = (t["trigger"] || t["platform"]).to_s
      out = case kind
      when "state" then state_like(t, "to", "from")&.merge({ "type" => "state" })
      when "numeric_state" then numeric(t)
      when "time" then time_triggers(t)
      when "sun" then { "type" => "sun", "event" => t["event"].to_s, "offset" => (duration(t["offset"]) if t["offset"]) }.compact
      when "time_pattern" then time_pattern(t)
      when "webhook" then { "type" => "webhook" }
      when "event" then event_trigger(t)
      when "homeassistant" then ({ "type" => "system", "event" => t["event"].to_s } if %w[start shutdown].include?(t["event"].to_s))
      when "template" then (e = @jinja.expr(t["value_template"].to_s)) && { "type" => "template", "expr" => e }
      when "mqtt" then { "type" => "mqtt", "topic" => t["topic"].to_s, "payload" => (t["payload"].to_s if t["payload"]) }.compact
      when "calendar" then calendar_trigger(t)
      when "device" then device_block(t)
      end
      out = Array.wrap(out).compact
      return note("gatilho #{kind.presence || '?'}") && [] if out.empty?

      out.map { |o| t["id"].present? ? o.merge("id" => t["id"].to_s) : o }
    end

    # Lote 5: vários horários, horário em segundos (32400) e horário vindo de
    # entidade (input_datetime → ponto de data e hora, `at_point`).
    def time_triggers(t)
      days = Array(t["weekday"]).filter_map { |d| WEEKDAYS.index(d.to_s) }.presence
      Array.wrap(t["at"]).filter_map do |at|
        at = clock(at) if at.is_a?(Integer)
        base = if input_ref?(at) then { "type" => "time", "at" => at }
        elsif at.is_a?(String) && at[0, 5].match?(Automations::Dsl::TIME) then { "type" => "time", "at" => at[0, 5] }
        elsif at.is_a?(String) && at.match?(ENTITY) && (k = entity_input(at)) then { "type" => "time", "at_point" => { "!input" => k } }
        else next note("gatilho time por entidade") && nil
        end
        base.merge({ "days" => days }.compact)
      end
    end

    def calendar_trigger(t)
      point = entity(t["entity_id"]) or return
      { "type" => "calendar", "point" => point, "event" => t["event"].to_s.presence_in(%w[start end]) || "start",
        "offset" => (duration(t["offset"]) if t["offset"]) }.compact
    end

    # Gatilho ou condição "de aparelho" do HA (type: turned_on, motion,
    # is_off...): vira estado ou faixa no ponto escolhido. Tipo com no_/not_
    # ou "off" = desligado; changed_states = qualquer mudança.
    def device_block(h)
      point = entity(h["entity_id"]) or return
      type = h["type"].to_s.delete_prefix("is_")
      return numeric(h) if h.key?("above") || h.key?("below")

      { "type" => "state", "point" => point, "to" => (device_state(type) unless type == "changed_states"),
        "for" => (duration(h["for"]) if h["for"]) }.compact
    end

    def device_state(type) = !type.match?(/\A(no|not)_|(\A|_)off\z/)

    # Lote 4 (G32): "/N" em minutos (ou horas) vira "a cada"; o resto não converte.
    def time_pattern(t)
      return { "type" => "time", "every" => "#{t['minutes'].to_s.delete_prefix('/')}m" } if t["minutes"].to_s.match?(%r{\A/\d+\z}) && t["hours"].blank?
      return { "type" => "time", "every" => "#{t['hours'].to_s.delete_prefix('/')}h" } if t["hours"].to_s.match?(%r{\A/\d+\z}) && t["minutes"].to_s.in?(%w[0 00])

      # ondaA1 (A5): o resto vira o "Padrão de tempo" (segundos inclusive).
      { "type" => "time_pattern", "hours" => t["hours"]&.to_s, "minutes" => t["minutes"]&.to_s, "seconds" => t["seconds"]&.to_s }.compact
    end

    # Evento com nome (G6): os dados do filtro só os que são texto simples.
    def event_trigger(t)
      name = t["event_type"].to_s
      return unless name.match?(Automations::Triggers::EVENT_NAME)

      data = t["event_data"].is_a?(Hash) ? t["event_data"].select { |_, v| v.is_a?(String) || v.is_a?(Numeric) }.transform_values(&:to_s) : {}
      { "type" => "event", "event" => name, "match" => data.presence }.compact
    end

    def condition(c)
      return expr_condition(c) if c.is_a?(String)
      return note("condição em texto (template)") && nil unless c.is_a?(Hash)

      kind = c["condition"].to_s
      ids = c["entity_id"]
      return { "type" => "and", "conditions" => ids.filter_map { |e| condition(c.merge("entity_id" => e)) } } if ids.is_a?(Array) && ids.size > 1

      out = case kind
      when "state" then state_like(c, "state", nil)&.then { |h| h.transform_keys { |k| k == "state" ? "is" : k } }&.merge({ "type" => "state" })
      when "numeric_state" then numeric(c)&.except("for")
      when "time"
        days = Array(c["weekday"]).filter_map { |d| WEEKDAYS.index(d.to_s) }
        after, before = clock(c["after"]), clock(c["before"])
        { "type" => "time", "after" => after || ("00:00" unless before), "before" => before, "days" => days.presence }.compact
      when "template" then return expr_condition(c["value_template"])
      when "trigger" then { "type" => "expr", "expr" => Array.wrap(c["id"]).map { |i| "trigger.id = '#{i.to_s.delete("'")}'" }.join(" or ") }
      when "and", "or", "not" then { "type" => kind, "conditions" => conditions(c["conditions"]) }
      when "sun" then sun_condition(c)
      when "device" then device_block(c)&.then { |h| h["type"] == "numeric" ? h.except("for") : h.except("to").merge("is" => h["to"]).compact }
      end
      out || (note("condição #{kind.presence || '?'}") && nil)
    end

    def sun_condition(c)
      { "type" => "sun", "after" => c["after"], "before" => c["before"], "after_offset" => (duration(c["after_offset"]) if c["after_offset"]),
        "before_offset" => (duration(c["before_offset"]) if c["before_offset"]) }.compact
    end

    # Lote 5: condição template do HA → expressão daqui (Blueprints::Jinja).
    def expr_condition(template)
      expr = @jinja.expr(template) or return note("condição template") && nil
      { "type" => "expr", "expr" => expr }
    end

    def state_like(h, to_key, from_key)
      point = entity(h["entity_id"]) or return
      # Lote 8: no gatilho o atributo vai junto (o valor dele, sem traduzir on/off); na condição fica anotado.
      attr = h["attribute"].presence&.to_s
      note("estado de atributo (#{attr})") if attr && !from_key
      out = { "point" => point, "attribute" => (attr if from_key) }.compact
      value = ->(v) { attr ? v : state_value(v) }
      out[to_key] = value.call(h[to_key]) if h.key?(to_key) && !h[to_key].is_a?(Array)
      out[from_key] = value.call(h[from_key]) if from_key && h.key?(from_key) && !h[from_key].is_a?(Array)
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
             "repeat" => :flow_repeat, "variables" => :flow_variables, "event" => :flow_event, "wait_for_trigger" => :flow_wait_trigger,
             "wait_template" => :flow_wait_template }.freeze

    # Serviço do HA → método (Lote 5).
    SERVICES = { "scene.turn_on" => :service_scene, "script.turn_on" => :service_script, "calendar.get_events" => :service_calendar,
                 "weather.get_forecasts" => :service_weather, "ai_task.generate_data" => :service_ai }.freeze
    # Serviço de helper do HA → comando daqui (o valor vem de `data`).
    HELPER_COMMANDS = { "set_value" => "set", "select_option" => "select", "set_datetime" => "set", "press" => "press",
                        "start" => "start", "cancel" => "cancel", "pause" => "pause", "finish" => "finish",
                        "increment" => "increment", "decrement" => "decrement", "reset" => "reset" }.freeze
    HELPER_DOMAINS = %w[input_number input_text input_select select input_datetime input_button button timer counter number].freeze
    MIRROR = /\A\w+\.turn_\{\{\s*trigger\.to_state\.state\s*\}\}\z/

    def action(a)
      return note("ação em texto") && [] unless a.is_a?(Hash)
      return delay(a["delay"]) if a.key?("delay")

      flow = FLOW.find { |k, _| a.key?(k) }
      return send(flow[1], a) if flow
      return Array.wrap(device_action(a)) if a["type"] && a["entity_id"] && !a.key?("action") && !a.key?("service")

      service = (a["action"] || a["service"]).to_s
      return note("ação #{(a.keys - IGNORED).first || '?'}") && [] if service.empty?

      service_action(service, a) || (note("ação #{service}") && [])
    end

    def service_action(service, a)
      domain, name = service.split(".", 2)
      if service.match?(MIRROR) then mirror(a)
      elsif SERVICES.key?(service) then send(SERVICES[service], a)
      elsif SWITCHES.include?(domain) && COMMANDS.key?(name) then switch_action(domain, name, a)
      elsif domain == "media_player" && MEDIA.include?(name) then media_action(name, a)
      elsif domain == "notify" || service == "persistent_notification.create"
        data = a["data"].is_a?(Hash) ? a["data"] : {}
        [ notify(data, domain == "notify" ? %w[in_app push] : %w[in_app]) ]
      elsif domain == "script" && (k = entity_input(service)) then service_script(a.merge("target" => { "entity_id" => { "!input" => k } }))
      elsif HELPER_DOMAINS.include?(domain) && HELPER_COMMANDS.key?(name) then helper_command(HELPER_COMMANDS[name], a)
      elsif domain == "vacuum" && VACUUM_COMMANDS.key?(name) then targets(a).map { |p| { "type" => "command", "point" => p, "command" => VACUUM_COMMANDS[name] } }.presence
      elsif LOG_SERVICES.include?(service) then log_action(a)
      elsif domain == "rest_command" && @rest[name].is_a?(Hash) then rest_command(@rest[name], a)
      elsif service == "homeassistant.reload_config_entry" || name == "reload" then reload_action(a, domain)
      end
    end

    # Liga/desliga/alterna (Lote 8): alvo por etiqueta ou área vira "Comandar
    # pontos por consulta"; brilho e cor do `light.turn_on` viram "Ajustar" no
    # ponto irmão (intensidade, cor) do mesmo aparelho.
    def switch_action(domain, name, a)
      data = a["data"].is_a?(Hash) ? a["data"] : {}
      extra = data.keys - %w[entity_id transition] - LIGHT_DATA.keys
      note("dados extras em #{domain}.#{name} (#{extra.join(', ')})") if extra.any?
      points = targets(a)
      out = points.map { |p| { "type" => "command", "point" => p, "command" => COMMANDS[name] } } + query_actions(domain, a, COMMANDS[name])
      return out unless name == "turn_on"

      out + data.slice(*LIGHT_DATA.keys).flat_map do |k, v|
        next note("#{k} com template do HA (confira)") && [] if v.to_s.include?("{{")

        cap, value = LIGHT_DATA[k].call(v)
        points.filter_map { |p| (s = sibling(p, cap)) && { "type" => "command", "point" => s, "command" => "set", "value" => value } }
      end
    end

    # Dado do light.turn_on → [capacidade do ponto irmão, valor do "Ajustar"].
    LIGHT_DATA = {
      "brightness_pct" => ->(v) { [ "dimmer", v.to_f.round.clamp(0, 100) ] },
      "brightness" => ->(v) { [ "dimmer", (v.to_f * 100 / 255).round.clamp(0, 100) ] },
      "rgb_color" => ->(v) { [ "color", { "rgb" => Array(v) } ] },
      "hs_color" => ->(v) { [ "color", { "hs" => Array(v) } ] },
      "color_temp_kelvin" => ->(v) { [ "color", { "kelvin" => v } ] },
      "kelvin" => ->(v) { [ "color", { "kelvin" => v } ] },
      "color_temp" => ->(v) { [ "color", { "mireds" => v } ] }
    }.freeze

    # Entrada irmã: o ponto de outra capacidade do mesmo aparelho (o
    # importador da instalação resolve pelo "#capacidade" no rótulo).
    def sibling(ref, cap)
      return unless input_ref?(ref) && (base = @inputs[ref["!input"]])

      k = "#{ref['!input']}_#{cap}".first(64)
      @inputs[k] ||= base.except("filter", "default").merge("key" => k, "label" => "#{base['label']}##{cap}", "filter" => { "capability" => [ cap ], "writable" => true })
      { "!input" => k }
    end

    # Alvo por etiqueta (`label_id`), área (`area_id`) ou andar (`floor_id`,
    # ondaA1) → consulta (uma por tipo de alvo, como a união do HA). O andar
    # importado fica em `areas` como "floor:<id>".
    def query_actions(domain, a, command)
      t = a["target"].is_a?(Hash) ? a["target"] : {}
      floors = Array.wrap(t["floor_id"]).map { |x| @areas.fetch("floor:#{x}", x).to_s }
      cap = DOMAIN_CAPS[domain] if domain != "homeassistant"
      labels = Array.wrap(t["label_id"]).map { |l| @labels.fetch(l, l).to_s.downcase }
      areas = Array.wrap(t["area_id"]).map { |x| @areas.fetch(x, x).to_s }
      note("alvo por área em #{domain}: aqui vale todo ponto liga/desliga da área (confira)") if areas.any? && domain == "light"
      [ ([ "tag", labels ] if labels.any?), ([ "area", areas ] if areas.any?), ([ "floor", floors ] if floors.any?) ].compact.filter_map do |key, names|
        next note("alvo com aspas no nome") && nil if names.join.match?(/["']/)

        list = names.join(",")
        query = [ "#{key}=#{list.include?(' ') ? "\"#{list}\"" : list}", ("capability=#{cap}" if cap) ].compact.join(" ")
        { "type" => "command_query", "query" => query, "command" => command }
      end
    end

    # media_player (G12, Lote 8): som, música, rotina e volume da Echo.
    MEDIA = %w[play_media volume_set].freeze
    MEDIA_TYPES = { "sound" => "sound", "routine" => "routine", "tts" => "speak", "announcement" => "announce" }.freeze

    def media_action(name, a)
      data = a["data"].is_a?(Hash) ? a["data"] : {}
      command, value = if name == "volume_set" then [ "volume", data["volume_level"].to_s.include?("{{") ? nil : (data["volume_level"].to_f * 100).round ]
      else
        type = data["media_content_type"].to_s
        id = data["media_content_id"].to_s
        id = text(id) if id.include?("{{")
        cmd = MEDIA_TYPES[type] || ("play" if Alexa::Client::PROVIDERS.include?(type.upcase))
        [ cmd, cmd == "play" ? "#{type.upcase}: #{id}" : id ]
      end
      return note("media_player.#{name} (#{data['media_content_type'] || 'valor com template'})") && nil if command.nil? || value.blank?

      targets(a).map { |p| { "type" => "command", "point" => p, "command" => command, "value" => value } }.presence
    end

    # `switch.turn_{{ trigger.to_state.state }}` (espelhar): se o gatilho ligou, liga; senão, desliga.
    def mirror(a)
      on, off = %w[on off].map { |c| targets(a).map { |p| { "type" => "command", "point" => p, "command" => c } } }
      return if on.empty?

      [ { "type" => "if", "conditions" => [ { "type" => "expr", "expr" => "trigger.value = true" } ], "then" => on, "else" => off } ]
    end

    def device_action(a)
      point = entity(a["entity_id"]) or return
      command = COMMANDS[a["type"].to_s] or return note("ação de aparelho #{a['type']}") && nil
      { "type" => "command", "point" => point, "command" => command }
    end

    def service_scene(a) = targets(a, "scene").map { |s| { "type" => "scene", "scene" => s } }.presence

    # Script é ponto daqui (capacidade script, comando run); campos constantes vão no valor.
    def service_script(a)
      fields = (a["data"].is_a?(Hash) ? a["data"] : {}).merge(a["variables"].is_a?(Hash) ? a["variables"] : {})
      dynamic = fields.values.any? { |v| v.to_s.include?("{{") }
      note("campos do script com template do HA (confira)") if dynamic
      targets(a).map { |p| { "type" => "command", "point" => p, "command" => "run", "value" => (fields.presence unless dynamic) }.compact }.presence
    end

    def helper_command(command, a)
      data = a["data"].is_a?(Hash) ? a["data"] : {}
      value = data.values_at("value", "option", "datetime", "time", "date", "duration").compact.first
      value = text(value) || (return note("valor com template do HA em #{command} (confira)") && nil) if value.to_s.include?("{{")

      targets(a).map { |p| { "type" => "command", "point" => p, "command" => command, "value" => value }.compact }.presence
    end

    def service_calendar(a)
      point = targets(a).first or return
      within = duration(a.dig("data", "duration")) if a.dig("data", "duration")
      return note("calendar.get_events com início/fim por template (use \"durante\")") && nil unless within

      [ { "type" => "calendar_events", "point" => point, "within" => within, "response_variable" => var_name(a["response_variable"], "agenda") } ]
    end

    def service_weather(a)
      point = targets(a).first or return
      [ { "type" => "weather_forecast", "point" => point, "kind" => a.dig("data", "type").to_s.presence_in(%w[daily hourly]) || "daily",
          "response_variable" => var_name(a["response_variable"], "clima") } ]
    end

    def service_ai(a)
      data = a["data"].is_a?(Hash) ? a["data"] : {}
      prompt = text(data["instructions"].to_s).presence or return
      note("ai_task: estrutura ou anexos (confira a saída e as imagens)") if data["structure"] || data["attachments"]
      [ { "type" => "ai_task", "prompt" => prompt, "response_variable" => var_name(a["response_variable"], "ia") } ]
    end

    def var_name(v, default) = v.to_s.downcase.gsub(/[^a-z0-9_]/, "_").presence || default

    def delay(v)
      return [ { "type" => "wait", "for" => duration(v) } ] unless v.to_s.include?("{{")

      expr = delay_expr(v) or return note("espera com template do HA") && []
      [ { "type" => "wait", "expr" => expr } ]
    end

    # Lote 7: espera por template → "segundos por expressão" ({minutes: "{{ x }}"} = x * 60).
    def delay_expr(v)
      return @jinja.expr(v) if v.is_a?(String)
      return unless v.is_a?(Hash)

      parts = v.map do |unit, x|
        mult = Jinja::SECONDS[unit.to_s] or return nil
        e = (x.is_a?(Numeric) ? x.to_s : @jinja.expr(x.to_s)) or return nil
        "(#{e}) * #{mult}"
      end
      parts.join(" + ").presence
    end

    # `logbook.log` / `system_log.write` → "Anotar" (linha no trace da execução).
    def log_action(a)
      data = a["data"].is_a?(Hash) ? a["data"] : {}
      msg = [ data["name"], data["message"] ].compact.map(&:to_s).join(": ")
      [ { "type" => "trace_note", "message" => (text(msg) || (note("texto com template do HA na anotação") && msg)).truncate(500) } ]
    end

    # `rest_command.x` → "Chamar HTTP" com o que está no configuration.yaml; os
    # campos da chamada viram variáveis antes (o template do rest_command lê pelo nome).
    def rest_command(spec, a)
      data = a["data"].is_a?(Hash) ? a["data"] : {}
      sets = flow_variables("variables" => data)
      url = text(spec["url"].to_s) or return note("rest_command com URL que não traduz") && nil
      body = spec["payload"] && (text(spec["payload"].to_s) or return note("rest_command com corpo que não traduz") && nil)
      headers = (spec["headers"].is_a?(Hash) ? spec["headers"].map { |k, v| "#{k}: #{v}" } : [])
      headers.unshift("Content-Type: #{spec['content_type']}") if spec["content_type"]
      method = spec["method"].to_s.upcase.presence_in(Automations::ActionTypes::HttpAction::METHODS.keys) || "GET"
      sets + [ { "type" => "http", "method" => method, "url" => url, "body" => body, "headers" => text(headers.join("\n")).presence,
                 "timeout" => (spec["timeout"].to_i.clamp(1, 30) if spec["timeout"]), "continue_on_error" => (true if a["continue_on_error"]) }.compact ]
    end

    # `homeassistant.reload_config_entry` (pelo id da integração, direto ou numa
    # variável constante) ou `<domínio>.reload` → "Recarregar integração" daqui.
    def reload_action(a, domain)
      if domain == "homeassistant"
        id = a.dig("data", "entry_id").to_s
        id = @consts[::Regexp.last_match(1)].to_s if id.match(/\A\{\{\s*(\w+)\s*\}\}\z/)
        domain = @entries[id]
      end
      plugin = HA_PLUGINS[domain.to_s] or return
      [ { "type" => "integration_reload", "integration" => plugin, "continue_on_error" => (true if a["continue_on_error"]) }.compact ]
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
      items = for_each(r["for_each"])
      return [ body.merge("for_each" => items) ] if items

      note("repetição #{(r.keys - %w[sequence]).first || '?'} (for_each)") && []
    end

    # Lote 5 (G22): lista de valores simples ou "{{ variavel }}".
    def for_each(v)
      return v.map(&:to_s).join(", ") if v.is_a?(Array) && v.all? { |x| x.is_a?(String) || x.is_a?(Numeric) } && v.none? { |x| x.to_s.include?(",") }

      expr = @jinja.expr(v) if v.is_a?(String)
      expr if expr&.match?(/\A[a-z_][a-z0-9_.]*\z/)
    end

    # Lote 5: o texto Jinja vira expressão (número, lógica) ou Liquid (texto).
    def flow_variables(a)
      vars = a["variables"].is_a?(Hash) ? a["variables"] : {}
      vars.filter_map do |k, v|
        set = { "type" => "set", "var" => k.to_s.downcase.gsub(/[^a-z0-9_]/, "_") }
        if v.is_a?(Numeric) || v == true || v == false then set.merge("expr" => v.to_s)
        elsif !v.is_a?(String) then note("variável #{k} com lista ou objeto") && nil
        elsif (expr = @jinja.expr(v)) then set.merge("expr" => expr)
        elsif (txt = text(v)) then set.merge("value" => txt)
        else note("variáveis com template do HA (confira o texto)") && set.merge("value" => v)
        end
      end
    end

    def flow_event(a)
      name = a["event"].to_s
      return note("evento #{name.truncate(40)}") && [] unless name.match?(Automations::Triggers::EVENT_NAME)

      data = (a["event_data"].is_a?(Hash) ? a["event_data"] : {}).to_h { |k, v| [ k.to_s, text(v.to_s) || note("dado do evento com template do HA") && v.to_s ] }
      [ { "type" => "fire_event", "event" => name, "data" => data.presence }.compact ]
    end

    def flow_wait_trigger(a)
      ts = list(a["wait_for_trigger"])
      ev = (event_trigger(ts.first) if ts.size == 1 && ts.first.is_a?(Hash) && (ts.first["trigger"] || ts.first["platform"]) == "event")
      return wait_state(ts.first, a) if ts.size == 1 && ts.first.is_a?(Hash) && (ts.first["trigger"] || ts.first["platform"]) == "state" && !ev
      return note("ação wait_for_trigger") && [] unless ev

      [ { "type" => "wait_event", "event" => ev["event"], "match" => ev["match"], "timeout" => (a["timeout"] ? duration(a["timeout"]) : "1h"),
          "continue_on_timeout" => (a["continue_on_timeout"] != false) }.compact ]
    end

    # Lote 8: esperar um estado (`to` [+ `for`]) = "Esperar condição" com
    # "Ponto está ... há pelo menos" (o motor reconfere sozinho). Sem tempo
    # limite no HA = o máximo daqui.
    def wait_state(t, a)
      return note("ação wait_for_trigger") && [] if !t.key?("to") || t["to"].is_a?(Array) || t["attribute"]

      point = entity(t["entity_id"]) or return []
      cond = { "type" => "state", "point" => point, "is" => state_value(t["to"]), "for" => (duration(t["for"]) if t["for"]) }.compact
      [ { "type" => "wait_for", "conditions" => [ cond ], "timeout" => (a["timeout"] ? duration(a["timeout"]) : "168h"),
          "continue_on_timeout" => (a["continue_on_timeout"] != false) } ]
    end

    def flow_wait_template(a)
      cond = expr_condition(a["wait_template"]) or return []
      [ { "type" => "wait_for", "conditions" => [ cond ], "timeout" => (a["timeout"] ? duration(a["timeout"]) : "1h") } ]
    end

    # Pontos (ou cenas) do alvo: `target` com entity_id/device_id, `entity_id` solto ou em `data`.
    def targets(a, type = "point")
      raw = a.key?("target") ? a["target"] : (a["entity_id"] || a.dig("data", "entity_id"))
      raw = Array.wrap(raw["entity_id"]) + Array.wrap(raw["device_id"]) if raw.is_a?(Hash) && !input_ref?(raw)
      Array.wrap(raw).filter_map { |e| entity(e, type) }
    end

    def notify(data, channels)
      title = data["title"].to_s.presence || "Aviso"
      message = data["message"].to_s.presence
      title, message = [ title, message ].map { |t| t && (text(t) || (note("texto com template do HA no aviso (confira: as variáveis do HA não existem aqui)") && t)) }
      { "type" => "notify", "channels" => channels, "title" => title.truncate(500), "message" => message&.truncate(500) }.compact
    end

    # Texto Jinja → Liquid (nil = não traduziu).
    def text(v) = @jinja.text(v)

    # ---- valores ----------------------------------------------------------------

    # Entidade: só pela entrada (ponto ou cena escolhida ao criar a automação).
    def entity(v, type = "point")
      v = v.first if v.is_a?(Array) && v.size == 1
      return v if input_ref?(v) && @inputs.dig(v["!input"], "type") == type

      note(v.is_a?(String) ? "entidade fixa #{v} (use uma entrada de ponto)" : "entidade #{v.inspect.truncate(60)}")
      nil
    end

    def input_ref?(v) = v.is_a?(Hash) && v.keys == [ "!input" ]

    # "18:00:00" ou 18000 (segundos) → "18:00"; entidade no horário fica anotada.
    def clock(v)
      return if v.nil?
      return format("%02d:%02d", *(v.to_i / 60).divmod(60)) if v.is_a?(Integer)
      return v.to_s[0, 5] if v.to_s[0, 5].match?(Automations::Dsl::TIME)

      note("horário #{v.to_s.truncate(40)} na condição") && nil
    end

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
