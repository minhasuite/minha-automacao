module Automations
  # A linguagem das automações (ESQUEMA-V1 §5): `{triggers, conditions,
  # actions}`. Uma tabela só (TRIGGERS/CONDITIONS/ACTIONS) diz os tipos, os
  # campos e o tipo de cada campo; dela saem a validação, o editor visual
  # (formulário por bloco) e a conversão do formulário. Validado à mão, como o
  # dashboard (Dashboards::Schema), porque a checagem depende do local
  # (ponto existe, comando serve para o ponto).
  #
  # Ponto: no JSON pode vir o UUID ou a `key` ("cozinha.luz"); ao salvar vira
  # UUID (`normalize`), o JSON avançado mostra a `key` (`with_keys`).
  # Duração: "30s", "5m", "1h30m" ou segundos (número); o sinal "-" só vale no
  # deslocamento do sol.
  module Dsl
    Field = Struct.new(:name, :kind, :label, :required, :options, keyword_init: true)

    def self.f(name, kind, label, required: false, options: nil) = Field.new(name: name, kind: kind, label: label, required: required, options: options)

    DAYS = %w[Dom Seg Ter Qua Qui Sex Sáb].freeze
    SUN_EVENTS = { "sunrise" => "Nascer do sol", "sunset" => "Pôr do sol" }.freeze
    QUALITIES = { "unavailable" => "Indisponível", "error" => "Com erro", "stale" => "Desatualizado", "good" => "Normal" }.freeze
    ALERT_EVENTS = { "open" => "Abriu", "ack" => "Alguém marcou ciente", "resolve" => "Fechou" }.freeze
    MODES = { "single" => "Uma por vez (ignora novo disparo)", "restart" => "Reinicia (cancela a anterior)",
              "queued" => "Em fila", "parallel" => "Em paralelo" }.freeze

    TRIGGERS = {
      "state" => { label: "Ponto mudou", fields: [ f("point", :point, "Ponto", required: true), f("from", :value, "De (opcional)"),
                                                  f("to", :value, "Para (opcional)"), f("for", :duration, "Por pelo menos") ] },
      "numeric" => { label: "Passou de um limite", fields: [ f("point", :point, "Ponto", required: true), f("above", :number, "Acima de"),
                                                             f("below", :number, "Abaixo de"), f("for", :duration, "Por pelo menos") ] },
      "time" => { label: "Horário", fields: [ f("at", :time, "Às (HH:MM)"), f("every", :duration, "Ou a cada (ex.: 10m)"), f("days", :days, "Dias") ] },
      "sun" => { label: "Sol", fields: [ f("event", :select, "Quando", required: true, options: SUN_EVENTS),
                                         f("offset", :duration, "Deslocamento (ex.: -15m)"), f("days", :days, "Dias") ] },
      "alert" => { label: "Alerta", fields: [ f("rule", :alert_rule, "Regra de alerta", required: true),
                                              f("on", :select, "Quando", required: true, options: ALERT_EVENTS) ] },
      "manual" => { label: "Manual (Executar agora)", fields: [] },
      "webhook" => { label: "Webhook (chamada externa com token)", fields: [] }
    }.freeze

    CONDITIONS = {
      "state" => { label: "Ponto está", fields: [ f("point", :point, "Ponto", required: true), f("is", :value, "Está"),
                                                 f("quality", :select, "Ou situação", options: QUALITIES), f("for", :duration, "Há pelo menos") ] },
      "numeric" => { label: "Ponto entre limites", fields: [ f("point", :point, "Ponto", required: true), f("above", :number, "Acima de"), f("below", :number, "Abaixo de") ] },
      "time" => { label: "Janela de horário", fields: [ f("after", :time, "Depois de"), f("before", :time, "Antes de"), f("days", :days, "Dias") ] },
      "sun" => { label: "Sol", fields: [ f("after", :select, "Depois do", options: SUN_EVENTS), f("after_offset", :duration, "Deslocamento"),
                                         f("before", :select, "Antes do", options: SUN_EVENTS), f("before_offset", :duration, "Deslocamento") ] },
      "expr" => { label: "Expressão", fields: [ f("expr", :expr, "Expressão (ex.: sala.temperatura > 28 and hour >= 22)", required: true) ] },
      "and" => { label: "Todas (e)", fields: [ f("conditions", :conditions, "Condições") ] },
      "or" => { label: "Alguma (ou)", fields: [ f("conditions", :conditions, "Condições") ] },
      "not" => { label: "Nenhuma (não)", fields: [ f("conditions", :conditions, "Condições") ] }
    }.freeze

    ACTIONS = {
      "command" => { label: "Comandar ponto", fields: [ f("point", :writable_point, "Ponto", required: true), f("command", :command, "Comando", required: true),
                                                        f("value", :value, "Valor (ajustar/selecionar)") ] },
      "scene" => { label: "Acionar cena", fields: [ f("scene", :scene, "Cena", required: true) ] },
      "notify" => { label: "Avisar", fields: [ f("channels", :channels, "Canais"), f("title", :template, "Título", required: true), f("message", :template, "Mensagem") ] },
      "wait" => { label: "Esperar", fields: [ f("for", :duration, "Tempo (ex.: 5m)"), f("expr", :expr, "Ou segundos por expressão") ] },
      "wait_for" => { label: "Esperar condição", fields: [ f("conditions", :conditions, "Até que"), f("timeout", :duration, "Tempo limite", required: true),
                                                           f("continue_on_timeout", :bool, "Seguir se o tempo acabar") ] },
      "if" => { label: "Se / senão", fields: [ f("conditions", :conditions, "Se"), f("then", :actions, "Então"), f("else", :actions, "Senão") ] },
      "choose" => { label: "Escolher", fields: [ f("options", :options, "Opções"), f("default", :actions, "Se nenhuma servir") ] },
      "repeat" => { label: "Repetir", fields: [ f("count", :number, "Vezes"), f("while", :conditions, "Enquanto"), f("until", :conditions, "Até que"),
                                                f("actions", :actions, "Fazer") ] },
      "set" => { label: "Definir variável", fields: [ f("var", :var, "Nome", required: true), f("expr", :expr, "Expressão (número/lógica)"),
                                                      f("value", :template, "Ou texto") ] },
      "condition" => { label: "Parar se falso", fields: [ f("conditions", :conditions, "Seguir só se") ] },
      "stop" => { label: "Parar", fields: [ f("reason", :text, "Motivo"), f("error", :bool, "Marcar como erro") ] }
    }.freeze

    OPTION = { label: "Opção", fields: [ f("conditions", :conditions, "Se"), f("actions", :actions, "Então") ] }.freeze

    # Campos simples (não lista) que o formulário de um bloco pode mandar.
    FORM_FIELDS = [ TRIGGERS, CONDITIONS, ACTIONS ].flat_map { |c| c.values.flat_map { |s| s[:fields] } }
                                                   .reject { |fd| fd.kind.in?(%i[conditions actions options days channels]) }.map(&:name).uniq.freeze

    # Lista de blocos → catálogo dos tipos dela.
    CATALOG = { triggers: TRIGGERS, conditions: CONDITIONS, actions: ACTIONS }.freeze
    LIST_KINDS = { conditions: CONDITIONS, actions: ACTIONS, options: { "option" => OPTION } }.freeze

    DURATION = /\A(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?\z/
    TIME = /\A([01]\d|2[0-3]):[0-5]\d\z/
    VAR = /\A[a-z_][a-z0-9_]*\z/
    MAX_REPEAT = 100
    MAX_DURATION = 7.days.to_i

    module_function

    def spec(kind, type)
      return OPTION if kind == :options

      LIST_KINDS.merge(triggers: TRIGGERS).fetch(kind)[type]
    end

    # "1h30m" / "-15m" / 90 → segundos (nil se inválida).
    def seconds(value)
      return value.to_i if value.is_a?(Numeric)

      s = value.to_s.strip.delete(" ")
      sign = s.delete_prefix!("-") ? -1 : 1
      return sign * Integer(s) if s.match?(/\A\d+\z/)

      m = DURATION.match(s) or return
      return if s.empty?

      sign * ((m[1].to_i * 3600) + (m[2].to_i * 60) + m[3].to_i)
    end

    def duration_label(sec)
      return "" if sec.nil?

      sign = sec.negative? ? "-" : ""
      h, rest = sec.abs.divmod(3600)
      m, s = rest.divmod(60)
      parts = [ ("#{h} h" if h.positive?), ("#{m} min" if m.positive?), ("#{s} s" if s.positive?) ].compact
      sign + (parts.join(" ").presence || "0 s")
    end

    def empty = { "triggers" => [], "conditions" => [], "actions" => [] }

    # Troca `key` por UUID nos campos de ponto e converte valores em texto para
    # o tipo do ponto ("true" → true). Referência desconhecida fica como veio
    # (a validação aponta).
    def normalize(definition, site)
      points = site.points.to_a
      by_ref = points.index_by(&:id).merge(points.index_by(&:key))
      walk(definition) do |node, kind|
        s = spec(kind, node["type"]) or next
        point = nil
        s[:fields].each do |fd|
          next unless node.key?(fd.name)

          if fd.kind.in?(%i[point writable_point]) && (point = by_ref[node[fd.name].to_s])
            node[fd.name] = point.id
          elsif fd.kind == :value && point && node[fd.name].is_a?(String)
            node[fd.name] = point.cast(node[fd.name])
          end
        end
      end
    end

    # Para o JSON avançado: UUID → key (mais legível).
    def with_keys(definition, site)
      keys = site.points.pluck(:id, :key).to_h
      walk(definition.deep_dup) do |node, kind|
        s = spec(kind, node["type"]) or next
        s[:fields].each { |fd| node[fd.name] = keys.fetch(node[fd.name], node[fd.name]) if fd.kind.in?(%i[point writable_point]) }
      end
    end

    # Visita cada bloco (gatilho, condição, ação, opção) com o tipo da lista
    # em que ele está. Devolve a própria definição.
    def walk(definition, &block)
      return definition unless definition.is_a?(Hash)

      CATALOG.each_key { |kind| walk_list(definition[kind.to_s], kind, &block) }
      definition
    end

    def walk_list(list, kind, &block)
      Array(list).each do |node|
        next unless node.is_a?(Hash)

        yield node, kind
        s = spec(kind, node["type"]) or next
        s[:fields].each { |fd| walk_list(node[fd.name], fd.kind, &block) if LIST_KINDS.key?(fd.kind) }
      end
    end

    # Pontos (UUID) citados em qualquer lugar da definição.
    def point_ids(definition)
      ids = []
      walk(definition) do |node, kind|
        s = spec(kind, node["type"]) or next
        s[:fields].each { |fd| ids << node[fd.name] if fd.kind.in?(%i[point writable_point]) && node[fd.name].present? }
      end
      ids.uniq
    end

    # Pontos comandados pelas ações (para papel x risco e confirmação).
    def commanded_points(definition, site)
      ids = []
      walk(definition) { |node, kind| ids << node["point"] if kind == :actions && node["type"] == "command" }
      ids.compact.empty? ? [] : site.points.where(id: ids.uniq).to_a
    end

    # Risco mais alto entre os pontos comandados.
    def max_risk(definition, site)
      commanded_points(definition, site).map(&:risk).max_by { |r| Point::RISKS.keys.index(r) } || "normal"
    end

    # Lista de mensagens ("ações 2 (Comandar ponto): ponto não existe neste local").
    def errors(definition, site)
      return [ "A definição precisa ser um objeto JSON." ] unless definition.is_a?(Hash)

      Validator.new(site).call(definition)
    end

    # Validação: chaves conhecidas, campos obrigatórios e tipos de cada campo.
    class Validator
      LIST_NAMES = { triggers: "gatilhos", conditions: "condições", actions: "ações", options: "opções" }.freeze

      def initialize(site)
        @site = site
        @points = site.points.includes(:device).index_by(&:id)
        @errors = []
      end

      def call(definition)
        extra = definition.keys - %w[triggers conditions actions]
        @errors << "Chave desconhecida: #{extra.join(', ')}." if extra.any?
        CATALOG.each_key { |kind| list(definition[kind.to_s], kind, LIST_NAMES[kind]) }
        @errors << "Falta pelo menos um gatilho." if Array(definition["triggers"]).empty?
        @errors << "Falta pelo menos uma ação." if Array(definition["actions"]).empty?
        @errors
      end

      private

      def list(value, kind, where)
        return if value.nil?
        return @errors << "#{where}: precisa ser uma lista." unless value.is_a?(Array)

        value.each_with_index { |node, i| block(node, kind, "#{where} #{i + 1}") }
      end

      def block(node, kind, where)
        return @errors << "#{where}: precisa ser um objeto." unless node.is_a?(Hash)

        type = kind == :options ? "option" : node["type"]
        s = Dsl.spec(kind, type) or return @errors << "#{where}: tipo \"#{node['type']}\" não existe."

        where = "#{where} (#{s[:label]})"
        names = s[:fields].map(&:name)
        extra = node.keys - names - %w[type id]
        @errors << "#{where}: campo desconhecido #{extra.join(', ')}." if extra.any?
        s[:fields].each do |fd|
          v = node[fd.name]
          next @errors << "#{where}: falta #{fd.label.downcase}." if fd.required && (v.nil? || v == "" || v == [])
          next if v.nil?

          field(fd, v, node, where)
        end
        rules(type, kind, node, where)
      end

      def field(fd, v, node, where)
        msg = case fd.kind
        when :point, :writable_point then point_error(v, fd.kind == :writable_point)
        when :duration then "duração inválida (use 30s, 5m, 1h30m)" unless (sec = Dsl.seconds(v)) && sec.abs <= MAX_DURATION
        when :number then "precisa ser número" unless v.is_a?(Numeric)
        when :time then "horário precisa ser HH:MM" unless v.is_a?(String) && TIME.match?(v)
        when :days then "dias precisam ser de 0 (dom) a 6 (sáb)" unless v.is_a?(Array) && v.any? && v.all? { |d| d.is_a?(Integer) && d.between?(0, 6) }
        when :select then "opção inválida" unless fd.options.key?(v)
        when :bool then "precisa ser verdadeiro ou falso" unless [ true, false ].include?(v)
        when :text then "texto longo demais" unless v.is_a?(String) && v.size <= 500
        when :var then "nome de variável inválido (letras minúsculas, números e _)" unless v.is_a?(String) && VAR.match?(v)
        when :expr then expr_error(v)
        when :template then template_error(v)
        when :channels then "canal inválido" unless Notifier.valid_channels?(v)
        when :scene then "cena não existe neste local" unless v.is_a?(String) && @site.scenes.exists?(id: v)
        when :alert_rule then "regra de alerta não existe neste local" unless v.is_a?(String) && @site.alert_rules.exists?(id: v)
        when :command then command_error(node, v)
        when :value then nil
        else list(v, fd.kind, "#{where} › #{fd.label.downcase}") && nil
        end
        @errors << "#{where}: #{fd.label.downcase}: #{msg}." if msg
      end

      def rules(type, kind, node, where)
        if kind == :triggers
          @errors << "#{where}: use \"às\" ou \"a cada\"." if type == "time" && node["at"].nil? == node["every"].nil?
          @errors << "#{where}: \"a cada\" precisa ser de 1 min a 24 h, em minutos inteiros." if type == "time" && node["every"] && !every_ok?(node["every"])
        end
        @errors << "#{where}: informe acima de e/ou abaixo de." if type == "numeric" && node["above"].nil? && node["below"].nil?
        @errors << "#{where}: informe o valor ou a situação." if kind == :conditions && type == "state" && !node.key?("is") && node["quality"].nil?
        @errors << "#{where}: informe depois de e/ou antes de." if type.in?(%w[time sun]) && kind == :conditions && node["after"].nil? && node["before"].nil?
        if kind == :actions
          @errors << "#{where}: informe o tempo ou a expressão." if type == "wait" && node["for"].nil? == node["expr"].nil?
          @errors << "#{where}: informe a expressão ou o texto." if type == "set" && node["expr"].nil? == node["value"].nil?
          @errors << "#{where}: informe vezes, enquanto ou até que (só um)." if type == "repeat" && %w[count while until].count { |k| node[k].present? } != 1
          @errors << "#{where}: no máximo #{MAX_REPEAT} vezes." if type == "repeat" && node["count"].is_a?(Numeric) && !node["count"].between?(1, MAX_REPEAT)
        end
      end

      def every_ok?(v)
        sec = Dsl.seconds(v)
        sec && sec.between?(60, 86_400) && (sec % 60).zero?
      end

      def point_error(id, writable)
        point = @points[id] or return "ponto não existe neste local"
        "#{point.name} não recebe comando" if writable && !point.writable
      end

      def command_error(node, command)
        point = @points[node["point"]] or return nil
        Points::Command.new(point, command.to_s, node["value"]).new_value
        nil
      rescue Points::Command::Error => e
        e.message.delete_suffix(".")
      end

      def expr_error(v)
        return "precisa ser texto" unless v.is_a?(String) && v.size <= 500

        Expr.calculator.ast(v)
        nil
      rescue Dentaku::Error, Dentaku::ParseError, Dentaku::TokenizerError => e
        "expressão inválida (#{e.message.truncate(80)})"
      end

      def template_error(v)
        return "precisa ser texto de até 500 caracteres" unless v.is_a?(String) && v.size <= 500

        Liquid::Template.parse(v, error_mode: :strict)
        nil
      rescue Liquid::Error => e
        "texto inválido (#{e.message.truncate(80)})"
      end
    end
  end
end
