module Dashboards
  # Painel do Home Assistant (Lovelace) → painel daqui, com a mesma
  # disposição: visão por visão, seção por seção, card por card, na mesma
  # ordem e largura (a seção do HA é uma grade de 12 colunas, como a daqui).
  #
  # Entrada: a configuração já resolvida pelo HA (`lovelace/config`, com os
  # !include e as âncoras expandidos) e os de-para da migração (`refs`).
  # Saída: a definição (schema_version 1) e as notas do que não veio igual.
  #
  # Card do HA = entrada em CARDS (tipo → método); recurso do tile = linha em
  # FEATURES; condição de visibilidade = método `cond_<nome>`. O que não tem
  # equivalente vira um Texto no mesmo lugar e tamanho, dizendo o que era, e
  # entra nas notas: o painel nunca perde a disposição.
  class HaImport
    Result = Data.define(:definition, :notes)

    # Largura padrão de cada card numa seção do HA (12 = linha inteira).
    DEFAULT_COLUMNS = { "tile" => 6, "entity" => 6, "button" => 3, "statistic" => 6, "sensor" => 6, "gauge" => 6,
                        "light" => 6, "thermostat" => 6, "humidifier" => 6 }.freeze
    CARDS = {
      "tile" => :tile, "entity" => :entity, "heading" => :heading, "markdown" => :markdown, "area" => :area,
      "button" => :button, "picture-entity" => :picture_entity, "picture" => :picture, "entities" => :entities,
      "glance" => :entities, "vertical-stack" => :stack, "horizontal-stack" => :stack, "grid" => :stack,
      "history-graph" => :history, "statistics-graph" => :history, "statistic" => :statistic, "sensor" => :entity,
      "gauge" => :gauge, "weather-forecast" => :weather, "thermostat" => :single, "humidifier" => :single,
      "light" => :single, "alarm-panel" => :single, "media-control" => :single, "map" => :map, "logbook" => :logbook,
      "calendar" => :calendar, "custom:atomic-calendar-revive" => :calendar, "todo-list" => :todo,
      "iframe" => :iframe, "conditional" => :conditional, "energy-devices-graph" => :energy_devices,
      "energy-date-selection" => :skip, "custom:auto-entities" => :auto_entities,
      "custom:casa-campo-texto" => :text_field, "custom:casa-grupo" => :group_card, "custom:casa-contador" => :counter_card,
      "ma:ai_usage" => :ai_usage_card
    }.freeze
    # Pacote de IA do HA da casa: o `sensor.ia_historico` (chamadas, falhas, gasto, histórico) e o `sensor.ia_pergunta`
    # (última resposta) viram os widgets daqui, que leem o próprio uso de IA (AiCall): `ai_usage`, `ai_log` e `ask`.
    AI_HISTORY = /\Asensor\.ia_historico\z/
    AI_ANSWER = /\bsensor\.ia_pergunta\b/
    SINGLE = { "thermostat" => "thermostat", "humidifier" => "humidifier", "light" => "light", "alarm-panel" => "alarm",
               "media-control" => "media" }.freeze
    # Recurso do tile do HA → recurso daqui (Dashboards::TileFeatures).
    FEATURES = {
      "light-brightness" => "brightness", "light-color-temp" => "color_temp", "cover-open-close" => "cover_open_close",
      "cover-position" => "cover_position", "cover-tilt" => "cover_tilt", "fan-speed" => "fan_speed",
      "fan-oscillate" => "fan_oscillate", "fan-direction" => "fan_direction", "fan-preset-modes" => "fan_preset",
      "climate-hvac-modes" => "climate_mode", "climate-fan-modes" => "climate_fan", "climate-preset-modes" => "climate_preset",
      "climate-swing-modes" => "climate_swing", "target-temperature" => "target_temperature",
      "target-humidity" => "target_humidity", "humidifier-modes" => "humidifier_mode",
      "water-heater-operation-modes" => "water_heater_mode", "vacuum-commands" => "vacuum_commands",
      "alarm-modes" => "alarm_modes", "lock-commands" => "lock_commands", "valve-open-close" => "valve_open_close",
      "select-options" => "select_options", "numeric-input" => "numeric_input",
      "media-player-volume-slider" => "media_volume", "media-player-playback" => "media_playback",
      "counter-actions" => "counter_actions", "toggle" => "power", "button" => "press", "trend-graph" => "trend",
      "bar-gauge" => "bar_gauge"
    }.freeze
    COLORS = { "amber" => "amber", "yellow" => "amber", "orange" => "amber", "deep-orange" => "amber",
               "green" => "green", "light-green" => "green", "teal" => "green", "lime" => "green",
               "red" => "red", "pink" => "red", "deep-red" => "red", "blue" => "blue", "light-blue" => "blue",
               "cyan" => "blue", "indigo" => "blue", "purple" => "accent", "deep-purple" => "accent", "primary" => "accent",
               "accent" => "accent" }.freeze
    SCREEN_BREAK = { mobile: 640, tablet: 1024 }.freeze
    MAX_GROUP = 8

    # refs: {"entity" => {entity_id => point_id}, "scene" => {entity_id => scene_id},
    #        "area" => {ha_area_id => area_id}, "dashboard" => {url_path => dashboard_id}}.
    # image: lambda(url do HA) → url daqui (ou nil); url_path: o caminho deste painel no HA.
    # `theme_dark`: o tema do HA usado nas visões é só escuro (as visões abrem no escuro, `theme.dark`).
    def initialize(config, refs:, url_path:, image: ->(_) { }, theme: nil, theme_dark: false)
      @config = config.to_h
      @refs = refs
      @url_path = url_path.to_s
      @image = image
      @theme = theme
      @theme_dark = theme_dark
      @notes = []
      @ids = Hash.new(0)
    end

    def call
      @area_views = {}
      views = Array(@config["views"]).each_with_index.map { |v, i| view(v.to_h, i) }
      # Cartão de área que abria uma visão deste painel: a visão fica ligada à
      # área (o cartão daqui navega para a visão da área).
      @area_views.each { |path, area| (v = views.find { |x| x["path"] == path }) && v["area"] ||= area }
      defn = { "schema_version" => Schema::VERSION, "views" => views }
      defn["theme"] = { "key" => @theme, "glass" => true } if @theme
      Result.new(definition: defn, notes: @notes.uniq)
    end

    private

    # ---- visão e seção -------------------------------------------------

    def view(v, i)
      path = slug(v["path"].presence || v["title"].presence || "visao-#{i + 1}")
      @where = v["title"].presence || path
      max = v["max_columns"].to_i.clamp(1, 4).nonzero? || 4
      out = { "id" => uid("v-#{path}"), "title" => v["title"].presence || path.humanize, "path" => path, "type" => view_type(v) }
      out["icon"] = v["icon"] if v["icon"].present?
      if ActiveModel::Type::Boolean.new.cast(v["subview"])
        out["subview"] = true
        out["back_path"] = nav_path(v["back_path"]) if v["back_path"].present?
      end
      theme = view_theme(v)
      out["theme"] = theme if theme
      out["badges"] = Array(v["badges"]).filter_map { |b| badge(b) } if v["badges"].present?
      out["sections"] = sections(v, max)
      out
    end

    def view_type(v) = { "masonry" => "masonry", "panel" => "panel", "sidebar" => "sidebar" }.fetch(v["type"].to_s, "sections")

    def view_theme(v)
      img = background(v["background"])
      return nil unless img || @theme

      { "key" => @theme || "aurora", "image" => img, "glass" => true, "dark" => (true if @theme_dark) }.compact
    end

    def background(bg)
      url = bg.is_a?(Hash) ? bg["image"] : bg.to_s[/url\(['"]?([^'")]+)/, 1]
      url.present? ? @image.call(url) : nil
    end

    # Seções do HA (colunas de até max_columns) → seções daqui (largura em 12).
    # Visão sem seções (masonry/panel): os cards viram uma seção cada.
    def sections(v, max)
      list = v["sections"] || Array(v["cards"]).map { |c| { "cards" => [ c ] } }
      list.each_with_index.filter_map do |s, si|
        s = s.to_h
        cond = visibility(s["visibility"])
        raw = s["type"].to_s == "grid" || s.key?("cards") ? Array(s["cards"]) : [ s ]
        cards = ai_cards(raw)
        spacer = cards.any? && cards.all? { |c| blank_markdown?(c.to_h) }
        widgets = spacer ? [] : cards.filter_map { |c| card(c.to_h, extra_visible: cond) }
        next if widgets.empty? && !spacer
        # Seção cujos cards saíram (fila de avaliação da IA do HA): sobrou só o título, então ela sai.
        next if !spacer && cards.size < raw.size && widgets.all? { |w| w["type"] == "heading" }

        span = (s["column_span"].to_i.nonzero? || 1).clamp(1, max)
        { "id" => uid("s-#{si + 1}"), "span" => { "mobile" => 12, "tablet" => span >= 2 || max == 1 ? 12 : 6,
                                                   "desktop" => (12 * span / max).clamp(1, 12) },
          "widgets" => widgets, "spacer" => (true if spacer) }.compact
      end
    end

    # Pacote de IA do HA (AI_HISTORY): os tiles seguidos do histórico viram um `ai_usage`; o markdown da linha
    # do tempo, um `ai_log`; o da última resposta (`sensor.ia_pergunta`) sai, porque o `ask` responde no card; e
    # o que só aparece pela fila de avaliação do HA (visibilidade pelo histórico) sai, porque aqui não há essa fila.
    def ai_cards(cards)
      out = []
      cards.each do |c|
        c = c.to_h
        content = c["content"].to_s
        if ai_history?(c["entity"])
          out << { "type" => "ma:ai_usage" } unless out.last&.dig("type") == "ma:ai_usage"
        elsif ai_history_visibility?(c["visibility"]) || content.match?(AI_ANSWER) || content.include?("pendente()") ||
              (c["type"] == "markdown" && ai_answer_visibility?(c["visibility"]))
          note_once("IA: a fila de avaliação e a última resposta do HA ficaram de fora (o card Perguntar à casa responde no painel)")
        elsif c["type"] == "markdown" && content.include?("linha_do_tempo")
          out << { "type" => "ma:ai_usage", "log" => true }
        else
          out << c
        end
      end
      out
    end

    def ai_history?(entity) = entity.to_s.match?(AI_HISTORY)
    def ai_history_visibility?(vis) = Array(vis).any? { |v| v.is_a?(Hash) && ai_history?(v["entity"]) }
    def ai_answer_visibility?(vis) = Array(vis).any? { |v| v.is_a?(Hash) && v["entity"].to_s.match?(AI_ANSWER) }
    def ai_usage_card(c) = c["log"] ? { "type" => "ai_log" } : { "type" => "ai_usage" }

    # ---- card ----------------------------------------------------------

    def card(c, extra_visible: nil, nested: false)
      type = c["type"].to_s
      m = CARDS[type]
      w = m ? send(m, c) : unsupported(c)
      return nil if w.nil? || w == :skip

      w["id"] = uid("w-#{w['type']}")
      cols = columns(c, type)
      cols = 12 if w["type"] == "heading"
      w["span"] = { "mobile" => cols, "tablet" => cols, "desktop" => cols } unless nested
      vis = merge_visible(merge_visible(w["visible_if"], visibility(c["visibility"])), extra_visible)
      w["visible_if"] = vis if vis
      w.compact
    end

    def columns(c, type)
      n = c.dig("grid_options", "columns") || c.dig("layout_options", "grid_columns")
      return 12 if n.to_s == "full"
      return (n.to_i * (n.to_i <= 4 && c.key?("layout_options") ? 3 : 1)).clamp(1, 12) if n.to_i.positive?

      DEFAULT_COLUMNS.fetch(type, 12)
    end

    def tile(c)
      return scene_widget(c) if scene?(c["entity"])

      w = bound("tile", c) or return missing(c)
      w["features"] = features(c["features"]) if c["features"].present?
      w["color"] = COLORS[c["color"].to_s] if c["color"].present?
      keep_command(w, actions(c))
    end

    def entity(c)
      w = bound("stat", c) or return missing(c)
      w["attribute"] = c["attribute"] if c["attribute"].present?
      w.merge(actions(c))
    end

    def single(c) = (bound(SINGLE.fetch(c["type"]), c) || missing(c))
    def gauge(c) = (w = bound("gauge", c)) ? w.merge(c.slice("min", "max").select { |_, v| v.is_a?(Numeric) }) : missing(c)
    def weather(c) = (w = bound("weather", c)) ? w.merge("forecast" => c["forecast_type"] == "hourly" ? "hourly" : "daily") : missing(c)
    # Campo de texto da casa: com seletor de Echo ou áudio é o "Falar na Alexa" (widget announce, envia direto
    # para a Echo); sem isso, o ponto de texto.
    def text_field(c)
      # Campo que pergunta à IA (`acao: script.ia_perguntar`) = o Perguntar à casa daqui.
      if c["acao"].to_s.match?(/perguntar/) || c["entity"].to_s.match?(/\Ainput_text\.ia_pergunta\z/)
        return { "type" => "ask", "label" => c["name"].presence, "icon" => (c["icon"] if Mdi.name?(c["icon"])),
                 "placeholder" => c["placeholder"].presence }.compact
      end
      if c["seletor"].present? || c["audio"].present? || c["acao"].to_s.include?("alexa")
        return { "type" => "announce", "label" => c["name"].presence, "icon" => (c["icon"] if Mdi.name?(c["icon"])),
                 "placeholder" => c["placeholder"].presence }.compact
      end

      (bound("tile", c) || missing(c)).tap { note(c, "o campo virou o ponto de texto (o botão do card próprio não vem)") }
    end
    def skip(_c) = :skip

    def heading(c)
      w = { "type" => "heading", "title" => c["heading"].presence || c["title"].presence || " " }
      w["icon"] = c["icon"] if c["icon"].present?
      w.merge(actions(c))
    end

    # Coluna vazia do HA (markdown só com "&nbsp;"/espaço, para segurar o alinhamento): seção espaçadora.
    def blank_markdown?(c)
      c["type"] == "markdown" && c["title"].blank? && c["content"].to_s.gsub(/&nbsp;|&#160;|<br\s*\/?>|\s/i, "").empty?
    end

    def markdown(c)
      return :skip if blank_markdown?(c)

      src = c["content"].to_s
      text = jinja&.text(src)
      note(c, "o Jinja do texto não foi traduzido; ficou o texto sem as partes {{ }}") if text.nil? && src.match?(/\{\{|\{%/)
      title = c["title"].present? ? "# #{c['title']}\n\n" : ""
      body = (text || src.gsub(/\{\{.*?\}\}|\{%.*?%\}/m, "")).strip
      { "type" => "markdown", "text" => (title + body).presence || " " }
    end

    def area(c)
      id = @refs.dig("area", c["area"].to_s) or return missing(c, "área #{c['area']} sem par aqui")
      w = { "type" => "area_card", "area" => id }
      if c["navigation_path"].present?
        to = nav_path(c["navigation_path"])
        to.start_with?("/") ? w["tap_action"] = { "action" => "navigate", "navigation_path" => to } : @area_views[to] ||= id
      end
      w
    end

    def button(c)
      if c["entity"].present?
        return scene_widget(c) if scene?(c["entity"])

        w = bound("button", c) or return missing(c)
      else
        w = { "type" => "button" }
        w["label"] = c["name"] if c["name"].present?
      end
      w["icon"] = c["icon"] if c["icon"].present?
      w["show_state"] = c["show_state"] != false
      keep_command(w, actions(c))
    end

    def picture_entity(c)
      if c["entity"].to_s.start_with?("camera.")
        w = bound("camera", c) or return missing(c, "câmera #{c['entity']} sem par aqui")
        return w.merge("live" => c["camera_view"].to_s == "live")
      end
      img = c["image"].presence && @image.call(c["image"])
      return missing(c) unless img

      { "type" => "image", "image" => img, "bind" => point(c["entity"]) }.compact.merge(actions(c))
    end

    def picture(c)
      img = @image.call(c["image"].to_s) or return missing(c, "imagem #{c['image']} não veio")
      { "type" => "image", "image" => img }.merge(actions(c))
    end

    # Lista de entidades → Grupo de pontos (até 8; mais que isso, pilha de grupos).
    def entities(c)
      binds = rows(c["entities"]).filter_map { |e| point(e) }
      lost = rows(c["entities"]).size - binds.size
      note(c, "#{lost} entidade(s) da lista sem par aqui") if lost.positive?
      return missing(c) if binds.empty?

      groups = binds.each_slice(MAX_GROUP).map { |b| { "type" => "group", "binds" => b } }
      groups.first["label"] = c["title"] if c["title"].present?
      groups.size == 1 ? groups.first : { "type" => "stack", "direction" => "vertical", "widgets" => groups.map { |g| g.merge("id" => uid("w-group")) } }
    end

    def stack(c)
      kids = Array(c["cards"]).first(Schema::MAX_CHILDREN).filter_map { |k| card(k.to_h, nested: true) }
      return missing(c) if kids.empty?

      dir = { "vertical-stack" => "vertical", "horizontal-stack" => "horizontal" }.fetch(c["type"], "grid")
      w = { "type" => "stack", "direction" => dir, "widgets" => kids }
      w["columns"] = (c["columns"] || 2).to_i.clamp(2, 4) if dir == "grid"
      w
    end

    def history(c)
      binds = rows(c["entities"]).filter_map { |e| point(e) }.first(MAX_GROUP)
      return missing(c) if binds.empty?

      hours = c["hours_to_show"]&.to_i || (c["days_to_show"]&.to_i || 1) * 24
      { "type" => "chart", "binds" => binds, "range" => if hours <= 24 then "24h" elsif hours <= 168 then "7d" else "30d" end,
        "label" => c["title"].presence }.compact
    end

    def statistic(c)
      w = bound("stat", c) or return missing(c)
      period = c.dig("period", "calendar", "period").to_s.presence_in(Schema::PERIODS)
      return w.merge("aggregate" => "change", "period" => period) if c["stat_type"].to_s == "change" && period

      w.merge("aggregate" => { "mean" => "avg", "min" => "min", "max" => "max", "change" => "sum" }.fetch(c["stat_type"].to_s, "last"))
    end

    def map(c) = { "type" => "map", "label" => c["title"].presence }.compact
    def iframe(c) = c["url"].to_s.start_with?("https://") ? { "type" => "iframe", "url" => c["url"] } : missing(c, "página sem https")
    def energy_devices(_c) = { "type" => "energy_breakdown", "period" => "today" }

    def logbook(c)
      binds = rows(c["entities"] || c["target"]&.dig("entity_id")).filter_map { |e| point(e) }.first(MAX_GROUP)
      { "type" => "logbook", "binds" => binds.presence, "limit" => 20 }.compact
    end

    def calendar(c)
      binds = rows(c["entities"]).filter_map { |e| point(e) }.first(MAX_GROUP)
      # Agendas sem par (a conta do Google ainda não ligada aqui): o card fica, com todas as agendas do local, e
      # mostra como ligar a agenda enquanto não houver nenhuma.
      note(c, "agendas sem par aqui: o card mostra todas as agendas do local") if binds.empty?
      { "type" => "calendar", "binds" => binds.presence, "days" => (c["maxDaysToShow"] || c["days_to_show"] || 3).to_i.clamp(1, 14) }.compact
    end

    def todo(c) = (bound("todo", c) || missing(c))

    # Cards próprios da casa (www/casa): grupo de tiles em colunas → grade;
    # contador (bolinha com número sobre um card) → o card de dentro.
    def group_card(c)
      stack(c.merge("type" => "grid", "columns" => c["columns"] || 3)).tap { |w| w["label"] = c["name"] if c["name"].present? && w["type"] == "stack" }
    end

    def counter_card(c)
      w = card(c["card"].to_h, nested: true) or return missing(c)
      note(c, "a bolinha com o número de #{c['entity']} sobre o card não vem")
      w.except("id")
    end

    # Condicional → o card de dentro com a condição.
    def conditional(c)
      inner = c["card"].to_h
      inner = inner.merge("visibility" => Array(inner["visibility"]) + Array(c["conditions"]).map { |x| x.to_h.reverse_merge("condition" => "state") })
      w = card(inner, nested: true)
      w&.except("id")
    end

    # auto-entities (HACS) → Lista automática: cada regra `include` vira uma consulta (somadas pelo `or`),
    # as `exclude` entram em todas; entidade fixa e curinga (`switch.*_luz`) viram os pontos do de-para.
    # Card de dentro com tiles (grid/vertical-stack) = grade de tiles; o `else` vira o texto de vazio.
    AE_DOMAINS = { "light" => { "capability" => "onoff,dimmer", "automation" => "false" },
                   "switch" => { "capability" => "onoff", "automation" => "false" },
                   "input_boolean" => { "capability" => "onoff", "automation" => "false" },
                   "media_player" => { "capability" => "media" }, "sensor" => { "capability" => "measure" },
                   "binary_sensor" => { "capability" => "contact,motion,tamper,problem" },
                   "automation" => { "automation" => "true" }, "cover" => { "capability" => "gate" },
                   "camera" => { "capability" => "stream" }, "vacuum" => { "capability" => "vacuum" },
                   "update" => { "capability" => "update" } }.freeze
    AE_INTEGRATIONS = { "alexa_media" => "alexa", "tuya" => "tuya", "localtuya" => "tuya_local", "xiaomi_home" => "miio",
                        "mqtt" => "mqtt", "esphome" => "esphome", "hue" => "hue", "shelly" => "shelly" }.freeze
    AE_SORTS = { "name" => "name", "state" => "value", "last_changed" => "changed_at", "last_updated" => "changed_at",
                 "last_triggered" => "ran_at" }.freeze

    def auto_entities(c)
      labels = {}
      excluded = ae_exclude(Array(c.dig("filter", "exclude")))
      queries = Array(c.dig("filter", "include")).filter_map { |rule| ae_rule(rule.to_h, labels) }.map { |q| q.merge(excluded) }
      return missing(c, "o filtro do auto-entities não tem equivalente direto") if queries.empty?

      sort = AE_SORTS[c.dig("sort", "method").to_s]
      queries[0] = queries[0].merge("sort" => "#{'-' if c.dig('sort', 'reverse') == true}#{sort}") if sort
      inner = c["card"].to_h
      # Pilha vertical vira a lista num card só (linhas compactas, como as do resto do painel); grade e pilha
      # horizontal ficam em tiles.
      tiles = %w[grid horizontal-stack].include?(inner["type"].to_s)
      columns = { "horizontal-stack" => 4 }[inner["type"].to_s] || inner["columns"].to_i.nonzero? || 3
      empty = c["show_empty"] == false ? " " : (c.dig("else", "content").to_s.strip.presence if c.dig("else", "type") == "markdown")
      { "type" => "query_list", "query" => queries.first, "or" => queries.drop(1).presence, "display" => ("tiles" if tiles), "columns" => (columns.clamp(1, 4) if tiles),
        "labels" => labels.presence, "label" => inner["title"].presence, "empty_text" => empty&.first(200) }.compact
    end

    AE_KEYS = %w[entity_id domain label area integration state last_triggered options attributes].freeze

    # Uma regra `include` → consulta (nil = nada daqui casa com ela). Campo que não sabemos traduzir
    # descarta a regra (melhor faltar item do que a lista encher de pontos que o HA não mostra).
    def ae_rule(rule, labels)
      attrs = rule["attributes"].to_h
      return note_once("auto-entities: regra com #{rule.keys - AE_KEYS} ficou de fora") && nil if (rule.keys - AE_KEYS).any?

      q = {}
      q["device_class"] = attrs.delete("device_class").to_s if attrs["device_class"].present?
      conds = attrs.map { |k, v| (m = v.to_s.strip.match(/\A(>=|<=|>|<)\s*(-?[\d.]+)\z/)) ? "#{k}#{m[1]}#{m[2]}" : "#{k}=#{v}" }
      q["attr"] = conds.join(",") if conds.any?
      if rule["entity_id"].present?
        ids = ae_entities(rule["entity_id"])
        return nil if ids.empty?

        q["id"] = ids.join(",")
        name = rule.dig("options", "name")
        ids.each { |id| labels[id] = name } if ids.size == 1 && name.is_a?(String) && name.present?
      end
      if rule["domain"].present?
        d = AE_DOMAINS[rule["domain"].to_s] or return nil
        q.merge!(d)
      end
      if rule["label"].present?
        name = @refs.dig("label", rule["label"].to_s) || rule["label"].to_s
        q["tag"] = name.downcase
      end
      if rule["area"].present?
        area = @refs.dig("area", rule["area"].to_s) or return nil
        q["area"] = area
      end
      if rule["integration"].present?
        driver = AE_INTEGRATIONS[rule["integration"].to_s] or return nil
        q["integration"] = driver
      end
      q.merge!(ae_state(rule["state"])) if rule.key?("state")
      q["ran_min"] = Regexp.last_match(1) if rule["last_triggered"].to_s =~ /\A\s*<\s*(\d+)/
      q.presence
    end

    def ae_state(v)
      s = v.to_s.strip
      case s
      # Sem sinal no HA é `unavailable`, nem on nem off: aqui o ponto guarda o último valor, então pede sinal.
      when "on", "playing", "open", "home", "true" then { "state" => "on", "quality" => "good" }
      when "off", "idle", "closed", "not_home", "false", "paused" then { "state" => "off", "quality" => "good" }
      when "unavailable", "unknown" then { "quality" => "unavailable" }
      when /\A<\s*(-?[\d.]+)\z/ then { "below" => Regexp.last_match(1) }
      when /\A>\s*(-?[\d.]+)\z/ then { "above" => Regexp.last_match(1) }
      else {}
      end
    end

    # As `exclude` que têm par aqui: entidades (com curinga) e integrações.
    def ae_exclude(rules)
      ids = rules.flat_map { |r| r.to_h["entity_id"].present? ? ae_entities(r["entity_id"]) : [] }
      drivers = rules.filter_map { |r| AE_INTEGRATIONS[r.to_h["integration"].to_s] }
      { "not_id" => ids.uniq.join(",").presence, "not_integration" => drivers.uniq.join(",").presence }.compact
    end

    # entity_id (ou curinga `*`, ou /regex/) → ids dos pontos do de-para.
    def ae_entities(pattern)
      pat = pattern.to_s
      map = @refs["entity"].to_h
      return [ map[pat] ].compact unless pat.include?("*") || pat.start_with?("/")

      re = pat.start_with?("/") ? (Regexp.new(pat[1...-1], timeout: 0.1) rescue nil) : nil
      map.select { |ext, _| re ? ext.match?(re) : File.fnmatch(pat, ext) }.values.uniq
    end

    # ---- ponto, cena e ações -------------------------------------------

    def bound(type, c)
      id = point(c["entity"]) or return nil
      w = { "type" => type, "bind" => id }
      cmd = command_of(c["entity"]) and w["tap_action"] = { "action" => "command", "point" => id, "command" => cmd }
      w["label"] = c["name"] if c["name"].is_a?(String) && c["name"].present?
      w["icon"] = c["icon"] if c["icon"].present?
      w
    end

    def point(e)
      e = e["entity"] if e.is_a?(Hash)
      @refs.dig("entity", e.to_s)
    end

    def rows(list) = Array(list).filter_map { |e| e.is_a?(Hash) ? (e["entity"].presence && e) : e.presence }
    def scene?(e) = e.to_s.start_with?("scene.") && @refs.dig("scene", e.to_s)
    def scene_widget(c) = { "type" => "scene_bar", "scenes" => [ @refs.dig("scene", c["entity"]) ] }

    def features(list)
      Array(list).filter_map do |f|
        key = FEATURES[f.to_h["type"].to_s] or next note_once("recurso #{f.to_h['type']} do tile sem equivalente")
        key
      end.uniq.presence
    end

    # O comando que a entidade é (ex.: lavar o pano) vale mais que o toque padrão do card do HA.
    def keep_command(w, acts) = w.merge(acts) { |k, mine, theirs| k == "tap_action" && mine["action"] == "command" && theirs["action"] != "command" ? mine : theirs }

    # tap/hold/double_tap do HA → os mesmos campos daqui (Dashboards::Actions).
    def actions(c)
      %w[tap_action hold_action double_tap_action].each_with_object({}) do |k, out|
        a = action(c[k]) and out[k] = a
      end
    end

    def action(a)
      return nil unless a.is_a?(Hash) && a["action"].present?

      out = case a["action"].to_s
      when "toggle" then { "action" => "toggle" }
      when "more-info" then { "action" => "more_info" }
      when "none" then { "action" => "none" }
      when "navigate" then { "action" => "navigate", "navigation_path" => nav_path(a["navigation_path"]) }
      when "url" then a["url_path"].to_s.start_with?("https://") ? { "action" => "url", "url" => a["url_path"] } : nil
      when "assist" then { "action" => "assist" }
      when "perform-action", "call-service" then service_action(a)
      end
      return note_once("ação #{a['action']} sem equivalente") && nil unless out

      out["confirmation"] = a["confirmation"].is_a?(Hash) ? (a.dig("confirmation", "text").presence || true) : true if a["confirmation"]
      out
    end

    # "Executar ação" do HA: script e liga/desliga/alternar de um ponto.
    def service_action(a)
      svc = (a["perform_action"] || a["service"]).to_s
      target = Array(a.dig("target", "entity_id") || a.dig("data", "entity_id") || a.dig("service_data", "entity_id")).first
      target = svc if svc.start_with?("script.") && !svc.end_with?(".turn_on", ".toggle")
      p = point(target) or return nil
      cmd = command_of(target) || { "turn_on" => "on", "turn_off" => "off", "toggle" => "toggle", "press" => "press" }[svc.split(".").last] || "run"
      { "action" => "command", "point" => p, "command" => cmd }
    end

    # Entidade do HA que aqui é um comando de outro ponto (botão "Lavar pano" → robô + wash_mop).
    def command_of(e) = @refs.dig("command", (e.is_a?(Hash) ? e["entity"] : e).to_s)

    # "/casa-home/cozinha" → "cozinha" (visão deste painel) ou "/paineis/<id>?view=..." (outro).
    def nav_path(path)
      dash, view = path.to_s.delete_prefix("/").split("/", 2)
      return slug(view.presence || "home") if dash == @url_path
      return path.to_s unless (id = @refs.dig("dashboard", dash))

      "/paineis/#{id}#{"?view=#{slug(view)}" if view.present?}"
    end

    # ---- visibilidade ----------------------------------------------------

    def visibility(list)
      conds = Array(list).filter_map { |c| condition(c.to_h) }
      return nil if conds.empty?

      conds.size == 1 ? conds.first : { "all" => conds.first(Schema::MAX_ANY) }
    end

    def condition(c)
      m = "cond_#{c['condition'].presence || (c.key?('state') || c.key?('state_not') ? 'state' : 'unknown')}"
      respond_to?(m, true) ? send(m, c) : note_once("condição #{c['condition']} sem equivalente (ignorada)") && nil
    end

    def cond_state(c)
      p = point(c["entity"]) or return note_once("condição com #{c['entity']} sem par (ignorada)") && nil
      c.key?("state_not") ? { "state" => { "point" => p, "not" => c["state_not"] } } : { "state" => { "point" => p, "is" => c["state"] } }
    end

    def cond_numeric_state(c)
      p = point(c["entity"]) or return nil
      n = { "point" => p, "above" => c["above"], "below" => c["below"] }.compact
      n.size > 1 ? { "numeric" => n.transform_values { |v| v.is_a?(String) && v.match?(/\A-?\d+(\.\d+)?\z/) ? v.to_f : v } } : nil
    end

    # "(min-width: 601px)" / "(max-width: 600px)" → telas daqui. O limite do HA
    # perto de um daqui (600 ≈ 640, 1024) encaixa nele.
    def cond_screen(c)
      q = c["media_query"].to_s
      min = snap(q[/min-width:\s*(\d+)/, 1])
      max = snap(q[/max-width:\s*(\d+)/, 1])
      ranges = { "mobile" => [ 0, SCREEN_BREAK[:mobile] - 1 ], "tablet" => [ SCREEN_BREAK[:mobile], SCREEN_BREAK[:tablet] - 1 ],
                 "desktop" => [ SCREEN_BREAK[:tablet], 99_999 ] }
      screens = ranges.select { |_, (lo, hi)| (min.nil? || lo >= min) && (max.nil? || hi < max) }.keys
      screens.size.between?(1, 2) ? { "screen" => screens } : nil
    end

    def snap(px)
      return nil if px.nil?

      v = px.to_i
      SCREEN_BREAK.values.find { |b| (v - b).abs <= 80 } || v
    end

    def cond_and(c) = visibility(c["conditions"])

    def cond_or(c)
      list = Array(c["conditions"]).filter_map { |x| condition(x.to_h) }.reject { |x| x.key?("screen") || x.key?("role") }
      list.any? ? { "any" => list.first(Schema::MAX_ANY) } : nil
    end

    def cond_user(_c) = note_once("condição por pessoa do HA não tem equivalente (o card aparece para todos)") && nil

    # Juntar duas condições (seção + card) num E; screen/role ficam por fora do `all`.
    def merge_visible(a, b)
      return a || b unless a && b

      outer = (a.slice("screen", "role")).merge(b.slice("screen", "role"))
      rest = [ a.except("screen", "role"), b.except("screen", "role") ].reject(&:empty?)
      out = outer.dup
      if rest.size == 1 then out.merge!(rest.first)
      elsif rest.size > 1 then out["all"] = rest.flat_map { |x| x.key?("all") && x.size == 1 ? x["all"] : [ x ] }.first(Schema::MAX_ANY)
      end
      out.presence
    end

    # ---- badge, texto de aviso e notas -----------------------------------

    def badge(b)
      b = b.to_h
      return nil unless b["entity"].present?
      return nil if ai_history?(b["entity"]) # os números da IA estão no card Uso de IA

      p = point(b["entity"]) or return note_once("badge de #{b['entity']} sem par aqui") && nil
      w = { "id" => uid("b"), "type" => "stat", "bind" => p, "aggregate" => "last" }
      w["label"] = b["name"] if b["name"].present? && b["show_name"] != false
      w["icon"] = b["icon"] if b["icon"].present?
      attr = Array(b["state_content"]).first.to_s
      w["attribute"] = attr if attr.present? && !%w[state name last_changed last_updated].include?(attr)
      vis = visibility(b["visibility"])
      w["visible_if"] = vis if vis
      w
    end

    def unsupported(c) = missing(c, "card #{c['type']} sem equivalente aqui")

    # Texto no lugar do card (mesmo tamanho), para a disposição não mudar.
    def missing(c, why = nil)
      why ||= c["entity"].present? ? "#{c['entity']} sem par aqui" : "card #{c['type']} incompleto"
      note(c, why)
      { "type" => "markdown", "text" => "*#{c['name'].presence || c['title'].presence || c['type']}*: #{why}." }
    end

    def note(c, why) = @notes << "#{@where}: #{c['name'].presence || c['entity'].presence || c['type']}: #{why}"
    def note_once(why) = (@notes << "#{@where}: #{why}") && false

    def jinja = @jinja ||= (@refs["jinja"] if @refs["jinja"].respond_to?(:text))

    def uid(prefix)
      base = prefix.gsub(/[^\w-]/, "-")[0, 80]
      n = (@ids[base] += 1)
      n == 1 ? base : "#{base}-#{n}"
    end

    def slug(s) = s.to_s.parameterize.tr("_", "-").gsub(/\A-+|-+\z/, "")[0, 40].presence || "visao"
  end
end
