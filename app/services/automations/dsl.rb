module Automations
  # A linguagem das automações (ESQUEMA-V1 §5): `{triggers, conditions,
  # actions}`. Cada tipo de bloco é um plugin (Block) registrado em
  # TriggerTypes, ConditionTypes e ActionTypes (F8f): ele diz os campos e o
  # tipo de cada campo; daqui saem a validação, o editor visual (formulário
  # por bloco) e a conversão do formulário. Validado à mão, como o dashboard
  # (Dashboards::Schema), porque a checagem depende do local (ponto existe,
  # comando serve para o ponto).
  #
  # Ponto: no JSON pode vir o UUID ou a `key` ("cozinha.luz"); ao salvar vira
  # UUID (`normalize`), o JSON avançado mostra a `key` (`with_keys`). Em
  # script, "$nome" = o ponto escolhido no campo `nome`.
  # Duração: "30s", "5m", "1h30m" ou segundos (número); o sinal "-" só vale no
  # deslocamento do sol.
  module Dsl
    Field = Struct.new(:name, :kind, :label, :required, :options, keyword_init: true) do
      # Opções do `:select`: hash fixo ou lambda lido na hora (registro de
      # plugins, como os provedores de IA e os tipos de consulta).
      def choices = options.respond_to?(:call) ? options.call : options
    end

    # Texto Liquid no lugar de um valor (Lote 7: o valor do comando vindo de template do HA).
    def self.template?(v) = v.is_a?(String) && (v.include?("{{") || v.include?("{%"))

    def self.f(name, kind, label, required: false, options: nil) = Field.new(name: name, kind: kind, label: label, required: required, options: options)

    DAYS = %w[Dom Seg Ter Qua Qui Sex Sáb].freeze
    SUN_EVENTS = { "sunrise" => "Nascer do sol", "sunset" => "Pôr do sol" }.freeze
    QUALITIES = { "unavailable" => "Indisponível", "error" => "Com erro", "stale" => "Desatualizado", "good" => "Normal" }.freeze
    ALERT_EVENTS = { "open" => "Abriu", "ack" => "Alguém marcou ciente", "resolve" => "Fechou" }.freeze
    MODES = { "single" => "Uma por vez (ignora novo disparo)", "restart" => "Reinicia (cancela a anterior)",
              "queued" => "Em fila", "parallel" => "Em paralelo" }.freeze

    # Pseudo-bloco das opções do "Escolher".
    class Option
      def self.label = "Opção"
      def self.fields = [ Dsl.f("conditions", :conditions, "Se"), Dsl.f("actions", :actions, "Então") ]
      def self.rules(_node) = []
      def self.defaults = {}
    end

    # Listas de blocos da definição → registro dos tipos (plugins).
    REGISTRIES = { triggers: "TriggerTypes", conditions: "ConditionTypes", actions: "ActionTypes" }.freeze
    KINDS = REGISTRIES.keys.freeze
    # Tipos de campo que são listas de blocos (aninhadas).
    LIST_KINDS = %i[conditions actions options].freeze
    # Tipos de campo que guardam um ponto (UUID no JSON, `key` no avançado).
    POINT_KINDS = %i[point writable_point camera].freeze
    # Listas de pontos (Lote 2: imagens de câmera e contexto da IA).
    POINT_LIST_KINDS = %i[cameras points].freeze
    # Campos que o formulário manda como lista (`name[]`).
    ARRAY_KINDS = %i[days channels cameras points areas tags].freeze
    MAX_PROMPT = 4_000

    DURATION = /\A(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?\z/
    TIME = /\A([01]\d|2[0-3]):[0-5]\d\z/
    VAR = /\A[a-z_][a-z0-9_]*\z/
    MAX_REPEAT = 100
    MAX_DURATION = 7.days.to_i

    module_function

    def registry(kind) = Automations.const_get(REGISTRIES.fetch(kind))
    def catalog(kind) = kind == :options ? { "option" => Option } : registry(kind).catalog
    def spec(kind, type) = kind == :options ? Option : registry(kind)[type]
    def list_kind?(kind) = LIST_KINDS.include?(kind)

    # Campos simples (não lista) que o formulário de um bloco pode mandar.
    def form_fields
      KINDS.flat_map { |k| registry(k).plugins.flat_map(&:fields) }
           .reject { |fd| fd.kind.in?(%i[conditions actions options script_fields] + ARRAY_KINDS) }.map(&:name).uniq
    end

    # Campos de lista do formulário ({nome => []}, para o `permit`).
    def array_form_fields
      KINDS.flat_map { |k| registry(k).plugins.flat_map(&:fields) }.select { |fd| fd.kind.in?(ARRAY_KINDS) }.map(&:name).uniq.index_with { [] }
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
        s.fields.each do |fd|
          next unless node.key?(fd.name)

          if fd.kind == :secret && node[fd.name].is_a?(String)
            node[fd.name] = encrypt_secret(node[fd.name])
          elsif fd.kind.in?(POINT_KINDS) && (point = by_ref[node[fd.name].to_s])
            node[fd.name] = point.id
          elsif fd.kind.in?(POINT_LIST_KINDS) && node[fd.name].is_a?(Array)
            node[fd.name] = node[fd.name].map { |ref| by_ref[ref.to_s]&.id || ref }
          elsif fd.kind == :value && point && node[fd.name].is_a?(String) && node["attribute"].blank? # atributo (Lote 8): texto como veio
            node[fd.name] = point.cast(node[fd.name])
          end
        end
      end
    end

    # Campo `:secret` (F9): texto em claro vira {"enc" => cifrado} ao salvar
    # (Active Record Encryption); só a ação lê de volta.
    def encrypt_secret(plain) = { "enc" => ActiveRecord::Encryption.encryptor.encrypt(plain) }

    def decrypt_secret(value)
      return value if value.nil? || value.is_a?(String)

      ActiveRecord::Encryption.encryptor.decrypt(value["enc"].to_s)
    rescue ActiveRecord::Encryption::Errors::Base
      nil
    end

    # Para o JSON avançado: UUID → key (mais legível).
    def with_keys(definition, site)
      keys = site.points.pluck(:id, :key).to_h
      walk(definition.deep_dup) do |node, kind|
        s = spec(kind, node["type"]) or next
        s.fields.each do |fd|
          node[fd.name] = keys.fetch(node[fd.name], node[fd.name]) if fd.kind.in?(POINT_KINDS)
          node[fd.name] = node[fd.name].map { |id| keys.fetch(id, id) } if fd.kind.in?(POINT_LIST_KINDS) && node[fd.name].is_a?(Array)
        end
      end
    end

    # Visita cada bloco (gatilho, condição, ação, opção) com o tipo da lista
    # em que ele está. Devolve a própria definição.
    def walk(definition, &block)
      return definition unless definition.is_a?(Hash)

      KINDS.each { |kind| walk_list(definition[kind.to_s], kind, &block) }
      definition
    end

    def walk_list(list, kind, &block)
      Array(list).each do |node|
        next unless node.is_a?(Hash)

        yield node, kind
        s = spec(kind, node["type"]) or next
        s.fields.each { |fd| walk_list(node[fd.name], fd.kind, &block) if list_kind?(fd.kind) }
      end
    end

    # Pontos (UUID) citados em qualquer lugar da definição.
    def point_ids(definition)
      ids = []
      walk(definition) do |node, kind|
        s = spec(kind, node["type"]) or next
        s.fields.each do |fd|
          ids << node[fd.name] if fd.kind.in?(POINT_KINDS) && node[fd.name].present?
          ids.concat(node[fd.name]) if fd.kind.in?(POINT_LIST_KINDS) && node[fd.name].is_a?(Array)
        end
      end
      ids.uniq
    end

    # Pontos comandados pelas ações (para papel x risco e confirmação); cada
    # plugin de ação diz os seus (`seen`: scripts já visitados).
    def commanded_points(definition, site, seen = Set.new)
      ids = []
      walk(definition) { |node, kind| ids.concat(ActionTypes[node["type"]]&.commanded_point_ids(node, site, seen).to_a) if kind == :actions }
      ids = ids.compact.uniq
      ids.empty? ? [] : site.points.where(id: ids).to_a
    end

    # Risco mais alto entre os pontos comandados.
    def max_risk(definition, site)
      commanded_points(definition, site).map(&:risk).max_by { |r| Point::RISKS.keys.index(r) } || "normal"
    end

    # Lista de mensagens ("ações 2 (Comandar ponto): ponto não existe neste local").
    # `fields`: campos do script (F8f) — definição de script não tem gatilho
    # nem condição e pode citar ponto de campo como "$nome".
    def errors(definition, site, fields: nil)
      return [ "A definição precisa ser um objeto JSON." ] unless definition.is_a?(Hash)

      Validator.new(site, fields).call(definition)
    end

    # Validação: chaves conhecidas, campos obrigatórios, o tipo de cada campo
    # e as regras do plugin (`rules`).
    class Validator
      LIST_NAMES = { triggers: "gatilhos", conditions: "condições", actions: "ações", options: "opções" }.freeze

      def initialize(site, fields = nil)
        @site = site
        @fields = fields&.index_by { |fd| fd["name"] }
        @points = site.points.includes(:device).index_by(&:id)
        @errors = []
      end

      def call(definition)
        extra = definition.keys - %w[triggers conditions actions]
        @errors << "Chave desconhecida: #{extra.join(', ')}." if extra.any?
        KINDS.each { |kind| list(definition[kind.to_s], kind, LIST_NAMES[kind]) }
        if @fields
          @errors << "Script não tem gatilho nem condição: quem chama é a automação, o painel, a API ou o botão Executar." if Array(definition["triggers"]).any? || Array(definition["conditions"]).any?
        elsif Array(definition["triggers"]).empty?
          @errors << "Falta pelo menos um gatilho."
        end
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

        where = "#{where} (#{s.label})"
        names = s.fields.map(&:name)
        extra = node.keys - names - %w[type id]
        @errors << "#{where}: campo desconhecido #{extra.join(', ')}." if extra.any?
        s.fields.each do |fd|
          v = node[fd.name]
          next @errors << "#{where}: falta #{fd.label.downcase}." if fd.required && (v.nil? || v == "" || v == [])
          next if v.nil?

          field(fd, v, node, where)
        end
        s.rules(node).each { |m| @errors << "#{where}: #{m}" }
      end

      def field(fd, v, node, where)
        msg = case fd.kind
        when :point, :writable_point then point_error(v, fd.kind == :writable_point)
        when :duration then "duração inválida (use 30s, 5m, 1h30m)" unless (sec = Dsl.seconds(v)) && sec.abs <= MAX_DURATION
        when :number then "precisa ser número" unless v.is_a?(Numeric)
        when :time then "horário precisa ser HH:MM" unless v.is_a?(String) && TIME.match?(v)
        when :days then "dias precisam ser de 0 (dom) a 6 (sáb)" unless v.is_a?(Array) && v.any? && v.all? { |d| d.is_a?(Integer) && d.between?(0, 6) }
        when :select then "opção inválida" unless fd.choices.key?(v)
        when :bool then "precisa ser verdadeiro ou falso" unless [ true, false ].include?(v)
        when :text then "texto longo demais" unless v.is_a?(String) && v.size <= 500
        when :secret then "segredo inválido" unless (v.is_a?(String) && v.size <= 500) || (v.is_a?(Hash) && v["enc"].is_a?(String))
        when :var then "nome de variável inválido (letras minúsculas, números e _)" unless v.is_a?(String) && VAR.match?(v)
        when :expr then expr_error(v)
        when :template then template_error(v)
        when :prompt then template_error(v, MAX_PROMPT)
        when :cameras then list_error(v) { |id| camera_error(id) }
        when :points then list_error(v) { |id| point_error(id, false) }
        when :areas then list_error(v) { |id| "área não existe neste local" unless @site.areas.exists?(id: id) }
        when :tags then list_error(v) { |id| "etiqueta não existe" unless Tag.exists?(id: id) }
        when :ai_output then Ai::Output.error(v)
        when :dataset then "conjunto de dados não existe neste local" unless v.is_a?(String) && @site.datasets.exists?(id: v)
        when :kv then "precisam ser {campo: texto}" unless v.is_a?(Hash) && v.size <= Dataset::MAX_FIELDS && v.all? { |k, x| k.is_a?(String) && x.is_a?(String) && x.size <= 500 }
        when :channels then "canal inválido" unless Notifier.valid_channels?(v)
        when :recipient then recipient_error(v)
        when :camera then camera_error(v, detection: true)
        when :buttons then nil # regras do plugin
        when :scene then "cena não existe neste local" unless v.is_a?(String) && @site.scenes.exists?(id: v)
        when :script then "script não existe neste local" unless v.is_a?(String) && @site.scripts.exists?(id: v)
        when :script_fields then script_fields_error(node, v)
        when :alert_rule then "regra de alerta não existe neste local" unless v.is_a?(String) && @site.alert_rules.exists?(id: v)
        when :command then command_error(node, v)
        when :value then nil
        else list(v, fd.kind, "#{where} › #{fd.label.downcase}") && nil
        end
        @errors << "#{where}: #{fd.label.downcase}: #{msg}." if msg
      end

      def recipient_error(v)
        return "destinatário inválido" unless Notifier.valid_recipient?(v)

        "pessoa não existe" if v.start_with?("user:") && !User.exists?(id: v.delete_prefix("user:"), tenant_id: @site.tenant_id)
      end

      # integ: no "Avisar", a detecção com IA também dá o quadro (o da detecção).
      def camera_error(id, detection: false)
        point = @points[id] or return "câmera não existe neste local"
        "#{point.name} não é câmera" unless point.capability == "stream" || (detection && point.capability == "detection")
      end

      def point_error(id, writable)
        return field_ref_error(id) if id.is_a?(String) && id.start_with?("$")

        point = @points[id] or return "ponto não existe neste local"
        "#{point.name} não recebe comando" if writable && !point.writable
      end

      # "$nome" = ponto escolhido no campo do script.
      def field_ref_error(ref)
        "campo #{ref} não existe no script (ou não é do tipo ponto)" unless @fields&.dig(ref.delete_prefix("$"), "type") == "point"
      end

      def script_fields_error(node, v)
        return "precisam ser um objeto {campo: valor}" unless v.is_a?(Hash)

        script = @site.scripts.find_by(id: node["script"]) if node["script"].is_a?(String)
        return unless script

        unknown = v.keys - script.fields.pluck("name")
        return "campo desconhecido #{unknown.join(', ')}" if unknown.any?

        missing = script.fields.select { |fd| fd["required"] && fd["default"].nil? && v[fd["name"]].blank? }
        "falta #{missing.pluck('label').join(', ').downcase}" if missing.any?
      end

      def command_error(node, command)
        point = @points[node["point"]] or return nil
        return template_error(node["value"]) if Dsl.template?(node["value"]) # o valor só existe na execução
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

      def list_error(v)
        return "precisa ser uma lista" unless v.is_a?(Array) && v.size <= 50 && v.all?(String)

        v.lazy.filter_map { |id| yield id }.first
      end

      def template_error(v, max = 500)
        return "precisa ser texto de até #{max} caracteres" unless v.is_a?(String) && v.size <= max

        Liquid::Template.parse(v, error_mode: :strict)
        nil
      rescue Liquid::Error => e
        "texto inválido (#{e.message.truncate(80)})"
      end
    end
  end
end
