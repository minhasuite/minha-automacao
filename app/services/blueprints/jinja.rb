module Blueprints
  # Lote 5 (G32): tradução do Jinja mais comum do HA para o que roda aqui.
  # Uma expressão `{{ ... }}` vira expressão do dentaku (condição, "Definir
  # variável") e um texto com `{{ ... }}` vira Liquid (aviso, título). Cobre
  # states(), is_state(), now() (hora, minuto, dia, mês, dia da semana,
  # strftime, isoformat), as_timestamp(now()), iif(), `a if c else b`, `in`
  # com lista, comparações, aritmética, and/or/not e os filtros
  # int/float/round/bool/trim/count/default/join. O que não cobre (state_attr,
  # namespace, `{% %}`, `is defined`, `states.x.y`...) devolve nil: o
  # importador anota, como antes.
  #
  # Entidade citada vira `[[entrada]]` (o `entity` diz a chave da entrada de
  # ponto); o Blueprint troca pela `key` do ponto escolhido ao criar a automação.
  class Jinja
    class Untranslatable < StandardError; end

    TOKEN = /\s*(?:(\d+(?:\.\d+)?)|'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)"|([A-Za-z_]\w*)|(\*\*|==|!=|<=|>=|[-+*\/%<>()\[\],.|~]))/
    ENTITY = /\A[a-z_]+\.[a-z0-9_]+\z/
    CMP = { "==" => "=", "!=" => "!=", "<" => "<", ">" => ">", "<=" => "<=", ">=" => ">=" }.freeze
    # Caminho do `trigger` do HA → o do gatilho daqui (Automations::Triggers).
    TRIGGER = { "trigger.to_state.state" => "trigger.value", "trigger.from_state.state" => "trigger.from", "trigger.id" => "trigger.id",
                "trigger.platform" => "trigger.type", "trigger.to_state.name" => "trigger.point", "trigger.event.event_type" => "trigger.event" }.freeze
    TRIGGER_DATA = /\Atrigger\.(?:event\.data|json)\.(\w+)\z/
    NOW = { "hour" => "hour", "minute" => "minute", "day" => "day", "month" => "month" }.freeze
    NUMERIC_FILTERS = %w[int float bool string trim].freeze
    LIQUID_FILTERS = { "trim" => "strip", "lower" => "downcase", "upper" => "upcase", "count" => "size", "length" => "size",
                       "round" => "round", "join" => "join", "default" => "default", "replace" => "replace", "int" => "floor", "float" => "plus: 0" }.freeze

    def initialize(entity)
      @entity = entity
    end

    # "{{ expressão }}" (só isso) → texto do dentaku, ou nil.
    def expr(src)
      m = src.to_s.strip.match(/\A\{\{(.*)\}\}\z/m) or return
      return if m[1].include?("{{") || m[1].include?("}}")

      dentaku(parse(m[1]))
    rescue Untranslatable
      nil
    end

    # Texto com "{{ }}" → Liquid, ou nil.
    def text(src)
      s = src.to_s
      return s unless s.include?("{{") || s.include?("{%")
      return if s.include?("{%")

      s.gsub(/\{\{(.*?)\}\}/m) { liquid(parse(::Regexp.last_match(1))) }
    rescue Untranslatable
      nil
    end

    private

    def fail! = raise(Untranslatable)

    # ---- parser (árvore em arrays) ---------------------------------------------

    def parse(src)
      @tokens = tokenize(src)
      @pos = 0
      node = ternary
      fail! if @pos < @tokens.size
      node
    end

    def tokenize(src)
      out = []
      rest = src.strip
      until rest.empty?
        m = TOKEN.match(rest) or fail!
        fail! unless m.begin(0).zero?
        out << if m[1] then [ :num, m[1].include?(".") ? m[1].to_f : m[1].to_i ]
        elsif m[2] || m[3] then [ :str, (m[2] || m[3]).gsub(/\\(.)/, '\1') ]
        elsif m[4] then [ :name, m[4] ]
        else [ :op, m[5] ]
        end
        rest = m.post_match.lstrip
      end
      out
    end

    def peek(type = nil, value = nil)
      t = @tokens[@pos] or return
      return if type && t[0] != type
      return if value && t[1] != value

      t
    end

    def accept(type, value = nil) = peek(type, value) && (@pos += 1) && @tokens[@pos - 1]
    def expect!(type, value = nil) = accept(type, value) || fail!
    def word?(w) = peek(:name, w)

    def ternary
      node = or_expr
      return node unless accept(:name, "if")

      cond = or_expr
      expect!(:name, "else")
      [ :if, cond, node, ternary ]
    end

    def or_expr = binary(:and_expr, %w[or])
    def and_expr = binary(:not_expr, %w[and])
    def not_expr = accept(:name, "not") ? [ :not, not_expr ] : comparison

    def binary(sub, words)
      node = send(sub)
      while (w = words.find { |x| word?(x) })
        @pos += 1
        node = [ :op, w, node, send(sub) ]
      end
      node
    end

    def comparison
      node = concat
      loop do
        if (t = peek(:op)) && CMP.key?(t[1]) then @pos += 1
                                                  node = [ :op, t[1], node, concat ]
        elsif word?("in") then @pos += 1
                               node = [ :in, node, concat, false ]
        elsif word?("not") && @tokens[@pos + 1] == [ :name, "in" ] then @pos += 2
                                                                     node = [ :in, node, concat, true ]
        elsif word?("is") then fail!
        else break
        end
      end
      node
    end

    def concat = arith(:additive, %w[~])
    def additive = arith(:term, %w[+ -])
    def term = arith(:power, %w[* / %])
    def power = arith(:unary, %w[**])

    def arith(sub, ops)
      node = send(sub)
      while (t = peek(:op)) && ops.include?(t[1])
        @pos += 1
        node = [ :op, t[1], node, send(sub) ]
      end
      node
    end

    def unary = accept(:op, "-") ? [ :neg, unary ] : postfix(primary)

    def postfix(node)
      loop do
        if accept(:op, ".") then node = [ :get, node, expect!(:name)[1] ]
        elsif accept(:op, "(") then node = [ :call, node, args(")") ]
        elsif accept(:op, "[") then fail!
        elsif accept(:op, "|") then name = expect!(:name)[1]
                                    node = [ :filter, name, node, accept(:op, "(") ? args(")") : [] ]
        else return node
        end
      end
    end

    def args(close)
      list = []
      until accept(:op, close)
        list << ternary
        accept(:op, ",") || peek(:op, close) || fail!
      end
      list
    end

    def primary
      t = @tokens[@pos] or fail!
      @pos += 1
      case t
      in [ :num, v ] then [ :lit, v ]
      in [ :str, v ] then [ :lit, v ]
      in [ :name, "true" | "True" ] then [ :lit, true ]
      in [ :name, "false" | "False" ] then [ :lit, false ]
      in [ :name, v ] then [ :var, v ]
      in [ :op, "(" ] then ternary.tap { expect!(:op, ")") }
      in [ :op, "[" ] then [ :list, args("]") ]
      else fail!
      end
    end

    # ---- leitura comum ----------------------------------------------------------

    # [:get, [:get, [:var, "a"], "b"], "c"] → "a.b.c" (nil se não for caminho).
    def path(node)
      case node
      in [ :var, name ] then name
      in [ :get, base, name ] then (p = path(base)) && "#{p}.#{name}"
      else nil
      end
    end

    # Variável do HA → caminho daqui (gatilho, repetição) ou o próprio nome.
    def variable(p, liquid: false)
      return TRIGGER[p] if TRIGGER.key?(p)
      return liquid ? p : "repeat_index" if p == "repeat.index"
      return liquid ? p : "repeat_item" if p == "repeat.item"
      return "trigger.data.#{::Regexp.last_match(1)}" if p.match(TRIGGER_DATA)
      fail! if p.start_with?("trigger.", "states.", "this.", "wait.") || p.in?(%w[trigger states this wait now none None])

      p
    end

    def entity_ref(arg)
      fail! unless arg in [ :lit, String => e ]
      fail! unless e.match?(ENTITY)
      key = @entity.call(e) or fail!
      "[[#{key}]]"
    end

    def call_name(node) = (node in [ :call, [ :var, name ], args ]) ? [ name, args ] : nil
    def now_call?(node) = (node in [ :call, [ :var, "now" ], [] ])

    # ---- dentaku ----------------------------------------------------------------

    def dentaku(node)
      case node
      in [ :lit, String => s ] then s.include?("'") ? fail! : "'#{s}'"
      in [ :lit, v ] then v.to_s
      in [ :list, _ ] then fail!
      in [ :neg, x ] then "-#{dentaku(x)}"
      in [ :not, x ] then "not(#{dentaku(x)})"
      in [ :if, c, a, b ] then "if(#{dentaku(c)}, #{dentaku(a)}, #{dentaku(b)})"
      in [ :in, x, [ :list, items ], neg ] then "#{'not' if neg}(#{items.map { |i| "#{dentaku(x)} = #{dentaku(i)}" }.join(' or ')})"
      in [ :in, * ] then fail!
      in [ :op, "~", * ] then fail!
      in [ :op, op, l, r ] then compare(op, l, r)
      in [ :filter, name, x, args ] then dentaku_filter(name, x, args)
      in [ :get, base, attr ] if now_call?(base) && NOW.key?(attr) then NOW[attr]
      in [ :call, [ :get, base, "weekday" ], [] ] if now_call?(base) then "((weekday + 6) % 7)"
      in [ :call, * ] then dentaku_call(node)
      else variable(path(node) || fail!)
      end
    end

    def compare(op, l, r)
      return "(#{dentaku(l)} #{op} #{dentaku(r)})" if %w[and or].include?(op)
      fail! if [ l, r ].any? { |x| x in [ :lit, String ] } && !CMP.key?(op)
      return "(#{dentaku(l)} ^ #{dentaku(r)})" if op == "**"
      return "(#{dentaku(l)} #{op} #{dentaku(r)})" if %w[+ - * / %].include?(op)

      l, r = [ l, r ].map { |side| state_literal(side, l, r) }
      "#{dentaku(l)} #{CMP.fetch(op)} #{dentaku(r)}"
    end

    # "on"/"off" comparado com states() de entidade vira sim/não (o valor do ponto daqui).
    def state_literal(side, l, r)
      other = side.equal?(l) ? r : l
      return side unless side in [ :lit, "on" | "off" ]
      return side unless call_name(other)&.first == "states" || (other in [ :filter, *, [ :call, [ :var, "states" ], _ ], _ ])

      [ :lit, side[1] == "on" ]
    end

    def dentaku_filter(name, x, args)
      return dentaku(x) if NUMERIC_FILTERS.include?(name)
      return "round(#{[ dentaku(x), *args.map { |a| dentaku(a) } ].join(', ')})" if name == "round"
      return "#{variable(path(x) || fail!)}.count" if %w[count length].include?(name)
      return "abs(#{dentaku(x)})" if name == "abs"

      fail!
    end

    def dentaku_call(node)
      name, args = call_name(node) || fail!
      case [ name, args.size ]
      in [ "states", 1 ] then entity_ref(args[0])
      in [ "is_state", 2 ] then "#{entity_ref(args[0])} = #{dentaku(state_value(args[1]))}"
      in [ "iif", 3 ] then "if(#{args.map { |a| dentaku(a) }.join(', ')})"
      in [ "as_timestamp", 1 ] if now_call?(args[0]) then "timestamp"
      in [ "float" | "int", 1 ] then dentaku(args[0])
      in [ "min" | "max" | "abs", _ ] then "#{name}(#{args.map { |a| dentaku(a) }.join(', ')})"
      else fail!
      end
    end

    def state_value(node) = (node in [ :lit, "on" | "off" ]) ? [ :lit, node[1] == "on" ] : node

    # ---- Liquid -----------------------------------------------------------------

    def liquid(node)
      case node
      in [ :op, "~", l, r ] then liquid(l) + liquid(r)
      in [ :lit, String => s ] then s.include?("{") ? fail! : s
      else "{{ #{liquid_value(node)} }}"
      end
    end

    def liquid_value(node)
      if (p = path(node)) then variable(p, liquid: true)
      elsif call_name(node)&.first == "states" then "points[\"#{entity_ref(node[2][0])}\"].text"
      elsif (node in [ :call, [ :get, base, "strftime" ], [ [ :lit, String => fmt ] ] ]) && now_call?(base) then "now | date: #{fmt.to_json}"
      elsif (node in [ :call, [ :get, base, "isoformat" ], [] ]) && now_call?(base) then "now | date: \"%Y-%m-%dT%H:%M:%S%:z\""
      elsif (node in [ :filter, name, x, args ]) && LIQUID_FILTERS.key?(name) && !(x in [ :lit, _ ])
        liquid_filter(name, liquid_value(x), args)
      else
        expr = dentaku(node)
        fail! if expr.include?('"')
        "\"#{expr}\" | calc"
      end
    end

    def liquid_filter(name, base, args)
      lit = args.map { |a| (a in [ :lit, v ]) ? v.to_json : fail! }
      return base if name == "string"
      return "#{base} | #{LIQUID_FILTERS[name]}" if lit.empty? || name.in?(%w[int float count length trim lower upper])

      "#{base} | #{LIQUID_FILTERS[name]}: #{lit.join(', ')}"
    end
  end
end
