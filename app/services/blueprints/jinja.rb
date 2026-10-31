module Blueprints
  # Lote 5 (G32): tradução do Jinja mais comum do HA para o que roda aqui.
  # Uma expressão `{{ ... }}` vira expressão do dentaku (condição, "Definir
  # variável") e um texto com `{{ ... }}` vira Liquid (aviso, título). Cobre
  # states(), is_state(), now() (hora, minuto, dia, mês, dia da semana,
  # strftime, isoformat), as_timestamp(now()), iif(), `a if c else b`, `in`
  # com lista, comparações, aritmética, and/or/not e os filtros
  # int/float/round/bool/trim/count/default/join. O que não cobre devolve
  # nil: o importador anota, como antes.
  #
  # Lote 7: os blocos `{% set %}`, `{% if/elif/else %}`, `{% for %}` (com
  # `if` e `.items()`) e `namespace()` viram Liquid (`assign`, `capture`,
  # `if`, `for`; o `ns.x` vira a variável `ns_x`); `x is (not) defined/none`
  # vira `defined('x')`; `states.d.o.last_changed`, `now() - ...`,
  # `.total_seconds()`, `timedelta()` e `as_local()` viram segundos
  # (`ponto.changed_at`, `timestamp`); `state_attr()` lê o atributo do ponto
  # (`ponto.attrs.nome`); `{...}.get(x, padrão)` vira `if()`; `.split()`,
  # `[n]` e `[:n]` no texto; `config_entry_attr(x, 'state')` vira
  # `integration_ok()`; e os conjuntos de entidades (`label_entities`,
  # `area_entities`, `integration_entities`, `states`, `states.dominio` com
  # `select`/`reject`/`selectattr` e `| count`) viram `count_points()` com a
  # consulta do Points::Query.
  #
  # Entidade citada vira `[[entrada]]` (o `entity` diz a chave da entrada de
  # ponto); o Blueprint troca pela `key` do ponto escolhido ao criar a automação.
  # `areas`/`labels` traduzem o id da área/etiqueta do HA para o nome daqui;
  # `entries` = id da integração do HA → domínio dela.
  class Jinja
    class Untranslatable < StandardError; end

    TOKEN = /\s*(?:(\d+(?:\.\d+)?)|'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)"|([A-Za-z_]\w*)|(\*\*|==|!=|<=|>=|[-+*\/%<>()\[\],.|~{}:=]))/
    ENTITY = /\A[a-z_]+\.[a-z0-9_]+\z/
    CMP = { "==" => "=", "!=" => "!=", "<" => "<", ">" => ">", "<=" => "<=", ">=" => ">=" }.freeze
    # Caminho do `trigger` do HA → o do gatilho daqui (Automations::Triggers).
    # O `event_type` da entidade de evento do HA é o valor do ponto daqui.
    TRIGGER = { "trigger.to_state.state" => "trigger.value", "trigger.from_state.state" => "trigger.from", "trigger.id" => "trigger.id",
                "trigger.platform" => "trigger.type", "trigger.to_state.name" => "trigger.point", "trigger.event.event_type" => "trigger.event",
                "trigger.to_state.attributes.event_type" => "trigger.value", "trigger.json" => "trigger.data", "trigger.event.data" => "trigger.data" }.freeze
    TRIGGER_DATA = /\Atrigger\.(?:event\.data|json)\.(\w+)\z/
    NOW = { "hour" => "hour", "minute" => "minute", "day" => "day", "month" => "month" }.freeze
    NUMERIC_FILTERS = %w[int float bool string trim].freeze
    LIQUID_FILTERS = { "trim" => "strip", "lower" => "downcase", "upper" => "upcase", "count" => "size", "length" => "size",
                       "round" => "round", "join" => "join", "default" => "default", "replace" => "replace", "int" => "floor", "float" => "plus: 0",
                       "sort" => "sort", "first" => "first", "last" => "last", "string" => "string" }.freeze
    # `states.ponto.x.<campo>` do HA.
    STATES_PATH = /\Astates\.([a-z_]+\.[a-z0-9_]+)\.(state|last_changed|last_updated|attributes\.(\w+))\z/
    SECONDS = { "weeks" => 604_800, "days" => 86_400, "hours" => 3600, "minutes" => 60, "seconds" => 1 }.freeze
    # Separador do item acrescentado à lista (`ns.l + [x]`): não aparece em texto.
    ITEM_SEP = "␞".freeze

    def initialize(entity, areas: {}, labels: {}, entries: {})
      @entity = entity
      @areas = areas
      @labels = labels
      @entries = entries
      @consts = {}
    end

    # Variáveis constantes da automação (`tuya_entry: 01K...`), para `config_entry_attr(tuya_entry, ...)`.
    attr_writer :consts

    # "{{ expressão }}" (só isso) → texto do dentaku, ou nil.
    def expr(src)
      m = src.to_s.strip.match(/\A\{\{(.*)\}\}\z/m) or return
      return if m[1].include?("{{") || m[1].include?("}}")

      @ns = {}
      dentaku(parse(m[1]))
    rescue Untranslatable
      nil
    end

    # Texto com "{{ }}" e "{% %}" → Liquid, ou nil.
    def text(src)
      s = src.to_s
      return s unless s.include?("{{") || s.include?("{%")

      @ns = {}
      @tmp = 0
      @stack = []
      out = s.split(/(\{\{.*?\}\}|\{%.*?%\})/m).map { |part| segment(part) }.join
      fail! if @stack.any?
      out
    rescue Untranslatable
      nil
    end

    private

    def fail! = raise(Untranslatable)

    def segment(part)
      if part.start_with?("{{") then liquid(parse(part[2..-3]))
      elsif part.start_with?("{%") then statement(part[2..-3].delete_prefix("-").delete_suffix("-").strip)
      elsif part.include?("{{") || part.include?("{%") then fail!
      else part
      end
    end

    # ---- blocos {% %} → Liquid --------------------------------------------------

    def statement(src)
      if (m = src.match(/\Aset\s+(\w+)(?:\.(\w+))?\s*=\s*(.+)\z/m)) then set_statement(m[1], m[2], m[3])
      elsif (m = src.match(/\Aif\s+(.+)\z/m)) then @stack << [ :if, 1 ]
                                                    cond_open(m[1])
      elsif (m = src.match(/\Aelif\s+(.+)\z/m)) then (@stack.last || fail!)[0] == :if || fail!
                                                      @stack.last[1] += 1
                                                      "{% else %}#{cond_open(m[1])}"
      elsif src == "else" then "{% else %}"
      elsif src == "endif" then close(:if) { |n| "{% endif %}" * n }
      elsif (m = src.match(/\Afor\s+(\w+)(?:\s*,\s*(\w+))?\s+in\s+(.+?)(?:\s+if\s+(.+))?\z/m)) then for_open(m[1], m[2], m[3], m[4])
      elsif src == "endfor" then close(:for) { |cond| "#{'{% endif %}' if cond}{% endfor %}" }
      else fail!
      end
    end

    def close(kind)
      top = @stack.pop
      fail! unless top && top[0] == kind
      yield top[1]
    end

    def tmp = "_j#{@tmp += 1}"

    def set_statement(name, attr, rhs)
      node = parse(rhs)
      if attr.nil? && (node in [ :call, [ :var, "namespace" ], kws ])
        @ns[name] = true
        return kws.map { |kw| (kw in [ :kw, k, v ]) ? assign("#{name}_#{k}", v) : fail! }.join
      end
      fail! if attr && !@ns[name]
      assign(attr ? "#{name}_#{attr}" : name, node)
    end

    # Valor por conta (`| calc`) quando dá; lista vazia; item acrescentado à
    # lista; senão o texto (`capture`).
    def assign(var, node)
      return "{% assign #{var} = \"\" | split: \",\" %}" if node == [ :list, [] ]
      if (node in [ :op, "+", base, [ :list, [ item ] ] ]) && path(base) && variable(path(base), liquid: true) == var
        return append(var, item)
      end

      "{% assign #{var} = #{calc_value(node)} %}"
    rescue Untranslatable
      "{% capture #{var} %}#{liquid(node)}{% endcapture %}"
    end

    def append(var, item)
      t = tmp
      "{% capture #{t} %}#{liquid(item)}{% endcapture %}{% assign #{t} = #{t} | split: \"#{ITEM_SEP}\" %}{% assign #{var} = #{var} | concat: #{t} %}"
    end

    def calc_value(node) = "#{quote(dentaku(node))} | calc"

    # Condição do `if`: variável sozinha usa o "vazio" do Liquid (lista vazia
    # e texto vazio são falsos, como no Jinja); o resto vai pela conta.
    def cond_open(src)
      node = src.is_a?(String) ? parse(src) : src
      return "{% if #{variable(path(node), liquid: true)} != blank %}" if path(node) && !path(node).start_with?("states.")
      return "{% if #{variable(path(node[1]), liquid: true)} == blank %}" if (node in [ :not, x ]) && path(x) && !path(x).start_with?("states.")

      t = tmp
      "{% assign #{t} = #{calc_value(node)} %}{% if #{t} %}"
    end

    def for_open(var, value_var, iter, cond)
      node = parse(iter)
      head = if value_var
        (node in [ :call, [ :get, base, "items" ], [] ]) && path(base) or fail!
        t = tmp
        "{% for #{t} in #{variable(path(base), liquid: true)} %}{% assign #{var} = #{t}[0] %}{% assign #{value_var} = #{t}[1] %}"
      elsif (node in [ :list, items ]) && items.all? { |i| i in [ :lit, String ] } && items.none? { |i| i[1].include?(",") }
        t = tmp
        "{% assign #{t} = #{items.map { |i| i[1] }.join(',').to_json} | split: \",\" %}{% for #{var} in #{t} %}"
      elsif path(node) && !path(node).start_with?("states")
        "{% for #{var} in #{variable(path(node), liquid: true)} %}"
      else fail!
      end
      @stack << [ :for, cond.present? ]
      head + (cond ? cond_open(cond) : "")
    end

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
        elsif word?("is") then @pos += 1
                               neg = accept(:name, "not") ? true : false
                               node = [ :test, expect!(:name)[1], node, neg ]
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
        elsif accept(:op, "[") then node = subscript(node)
        elsif accept(:op, "|") then name = expect!(:name)[1]
                                    node = [ :filter, name, node, accept(:op, "(") ? args(")") : [] ]
        else return node
        end
      end
    end

    # `x[n]`, `x[-1]`, `x[:n]`.
    def subscript(node)
      if accept(:op, ":")
        hi = ternary
        expect!(:op, "]")
        return [ :slice, node, nil, hi ]
      end
      idx = ternary
      expect!(:op, "]")
      idx = [ :lit, -idx[1][1] ] if idx in [ :neg, [ :lit, Integer ] ]
      [ :index, node, idx ]
    end

    # Argumentos, com `nome=valor` (namespace, timedelta).
    def args(close)
      list = []
      until accept(:op, close)
        list << if peek(:name) && @tokens[@pos + 1] == [ :op, "=" ]
          name = expect!(:name)[1]
          @pos += 1
          [ :kw, name, ternary ]
        else ternary
        end
        accept(:op, ",") || peek(:op, close) || fail!
      end
      list
    end

    def dict
      pairs = []
      until accept(:op, "}")
        k = ternary
        expect!(:op, ":")
        pairs << [ k, ternary ]
        accept(:op, ",") || peek(:op, "}") || fail!
      end
      [ :dict, pairs ]
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
      in [ :op, "{" ] then dict
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

    # Variável do HA → caminho daqui (gatilho, repetição, namespace) ou o próprio nome.
    def variable(p, liquid: false)
      head, rest = p.split(".", 2)
      return "#{head}_#{rest}" if @ns&.key?(head) && rest&.match?(/\A\w+\z/)
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

    # `states.ponto.x.last_changed` etc. → ponto daqui (segundos, valor ou atributo).
    def states_path(p, liquid: false)
      m = p.match(STATES_PATH) or return
      ref = entity_ref([ :lit, m[1] ])
      base = liquid ? "points[\"#{ref}\"]" : ref
      return "#{base}.attrs.#{m[3]}" if m[3]
      return (liquid ? "#{base}.text" : ref) if m[2] == "state"

      "#{base}.changed_at"
    end

    def attr_ref(args, liquid: false)
      fail! unless (args[1] in [ :lit, String => a ]) && a.match?(/\A\w+\z/)
      ref = entity_ref(args[0])
      liquid ? "points[\"#{ref}\"].attrs.#{a}" : "#{ref}.attrs.#{a}"
    end

    def call_name(node) = (node in [ :call, [ :var, name ], args ]) ? [ name, args ] : nil
    def now_call?(node) = (node in [ :call, [ :var, "now" ], [] ])

    # Texto para dentro de aspas (do dentaku ou do Liquid), sem escapar.
    def quote(s)
      return "'#{s}'" unless s.include?("'")
      return "\"#{s}\"" unless s.include?('"')

      fail!
    end

    # ---- dentaku ----------------------------------------------------------------

    def dentaku(node)
      case node
      in [ :lit, String => s ] then quote(s)
      in [ :lit, v ] then v.to_s
      in [ :list, _ ] | [ :dict, _ ] | [ :kw, * ] | [ :slice, * ] then fail!
      in [ :neg, x ] then "-#{dentaku(x)}"
      in [ :not, x ] then "not(#{dentaku(x)})"
      in [ :if, c, a, b ] then "if(#{dentaku(c)}, #{dentaku(a)}, #{dentaku(b)})"
      in [ :test, name, x, neg ] then test(name, x, neg)
      in [ :in, x, [ :list, items ], neg ] then "#{'not' if neg}(#{items.map { |i| "#{dentaku(x)} = #{dentaku(i)}" }.join(' or ')})"
      in [ :in, * ] then fail!
      in [ :op, "~", * ] then fail!
      in [ :op, op, l, r ] then compare(op, l, r)
      in [ :filter, name, x, args ] then dentaku_filter(name, x, args)
      in [ :index, base, [ :lit, Integer => i ] ] if i >= 0 && path(base) then "#{variable(path(base))}.#{i}"
      in [ :index, [ :dict, pairs ], key ] then dict_get(pairs, key, nil)
      in [ :index, * ] then fail!
      in [ :get, base, attr ] if now_call?(base) && NOW.key?(attr) then NOW[attr]
      in [ :call, [ :get, base, "weekday" ], [] ] if now_call?(base) then "((weekday + 6) % 7)"
      in [ :call, [ :get, base, "total_seconds" | "timestamp" ], [] ] then seconds(base)
      in [ :call, [ :get, [ :dict, pairs ], "get" ], [ key, *default ] ] then dict_get(pairs, key, default.first)
      in [ :call, * ] then dentaku_call(node)
      else (p = path(node) || fail!) && (states_path(p) || variable(p))
      end
    end

    # Data e hora em segundos (now() e o ponto mudou em); a diferença também.
    def seconds(node)
      out = dentaku(node)
      return out if out == "timestamp" || out.end_with?(".changed_at") || (node in [ :op, "-" | "+", _, _ ])

      fail!
    end

    # Data e hora em segundos; texto (ISO) pela função `to_timestamp` da calculadora.
    def timestamp_of(node)
      seconds(node)
    rescue Untranslatable
      "to_timestamp(#{dentaku(node)})"
    end

    def test(name, x, neg)
      fail! unless %w[defined none].include?(name)
      inner = dentaku(x)
      fail! unless inner.match?(/\A[\w.\[\]]+\z/)
      d = "defined('#{inner}')"
      (name == "none") ^ neg ? "not(#{d})" : d
    end

    def dict_get(pairs, key, default)
      k = dentaku(key)
      pairs.reverse.reduce(default ? dentaku(default) : "''") do |acc, (pk, pv)|
        fail! unless pk in [ :lit, String ]
        "if(#{k} = #{dentaku(pk)}, #{dentaku(pv)}, #{acc})"
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
      # Lote 8: `expand('a', 'b') | map(attribute='last_changed') | max` → o mais recente dos pontos.
      if %w[max min].include?(name) && (x in [ :filter, "map", [ :call, [ :var, "expand" ], ents ], [ [ :kw, "attribute", [ :lit, "last_changed" | "last_updated" ] ] ] ])
        return "#{name}(#{ents.map { |e| "#{entity_ref(e)}.changed_at" }.join(', ')})"
      end
      return "round(#{[ dentaku(x), *args.map { |a| dentaku(a) } ].join(', ')})" if name == "round"
      if %w[count length].include?(name)
        q = query(x)
        return q ? "count_points('#{q}')" : "#{variable(path(x) || fail!)}.count"
      end
      return "abs(#{dentaku(x)})" if name == "abs"
      return "if(defined('#{variable(path(x))}'), #{variable(path(x))}, #{args.any? ? dentaku(args[0]) : "''"})" if name == "default" && path(x)

      fail!
    end

    def dentaku_call(node)
      name, args = call_name(node) || fail!
      case [ name, args.size ]
      in [ "states", 1 ] then entity_ref(args[0])
      in [ "is_state", 2 ] then "#{entity_ref(args[0])} = #{dentaku(state_value(args[1]))}"
      in [ "state_attr", 2 ] then attr_ref(args)
      in [ "is_state_attr", 3 ] then "#{attr_ref(args)} = #{dentaku(args[2])}"
      in [ "iif", 3 ] then "if(#{args.map { |a| dentaku(a) }.join(', ')})"
      in [ "now", 0 ] then "timestamp"
      in [ "as_timestamp" | "as_local" | "as_datetime", 1 ] then timestamp_of(args[0])
      in [ "timedelta", _ ] then timedelta(args)
      in [ "config_entry_attr", 2 ] then config_entry(args)
      in [ "float" | "int", 1 ] then dentaku(args[0])
      in [ "min" | "max" | "abs", _ ] then "#{name}(#{args.map { |a| dentaku(a) }.join(', ')})"
      else fail!
      end
    end

    def timedelta(args)
      args.sum { |a| (a in [ :kw, unit, [ :lit, Numeric => n ] ]) && SECONDS.key?(unit) ? n * SECONDS[unit] : fail! }.to_s
    end

    # Estado da integração do HA → integração daqui conectada ("loaded" = ok).
    def config_entry(args)
      fail! unless args[1] == [ :lit, "state" ]
      id = (args[0] in [ :lit, String => s ]) ? s : @consts[path(args[0]).to_s]
      plugin = HaImport::HA_PLUGINS[@entries[id.to_s]] or fail!
      "if(integration_ok('#{plugin}'), 'loaded', 'not_loaded')"
    end

    def state_value(node) = (node in [ :lit, "on" | "off" ]) ? [ :lit, node[1] == "on" ] : node

    # ---- conjunto de entidades → consulta do Points::Query ------------------------

    # nil = não é conjunto de entidades (o `| count` segue como antes).
    def query(node)
      case node
      in [ :filter, "list", inner, [] ] then query(inner)
      in [ :filter, "select" | "reject" => f, inner, [ [ :lit, String => test ], *rest ] ] then (q = query(inner)) && join_query(q, select_part(f == "select", test, rest))
      in [ :filter, "selectattr" | "rejectattr" => f, inner, [ [ :lit, "state" ], [ :lit, "eq" | "==" | "equalto" ], [ :lit, String => v ] ] ]
        (q = query(inner)) && join_query(q, state_part(f == "selectattr", v))
      in [ :var, "states" ] then ""
      in [ :get, [ :var, "states" ], domain ] then "capability=#{HaImport::DOMAIN_CAPS[domain] || fail!}"
      in [ :call, [ :var, "label_entities" ], [ [ :lit, String => l ] ] ] then "tag=#{query_value(@labels.fetch(l, l))}"
      in [ :call, [ :var, "area_entities" ], [ [ :lit, String => _ ] ] ] then "area=#{query_value(areas(node).join(','))}"
      in [ :call, [ :var, "integration_entities" ], [ [ :lit, String => d ] ] ] then "integration=#{HaImport::HA_DRIVERS[d] || fail!}"
      else nil
      end
    end

    def join_query(a, b) = [ a, b ].compact_blank.join(" ")

    def select_part(select, test, rest)
      return state_part(select, rest[0][1]) if test == "is_state" && (rest in [ [ :lit, String ] ])
      return "area=#{query_value(areas(rest[0]).join(','))}" if test == "in" && select && rest.size == 1

      fail!
    end

    def state_part(select, v)
      case v
      when "on", "off" then "state=#{select ? v : (%w[on off] - [ v ]).first}"
      when "unavailable" then select ? "quality=unavailable" : "quality=good,stale,error"
      else fail!
      end
    end

    # `area_entities('a') + area_entities('b')` → nomes das áreas daqui.
    def areas(node)
      case node
      in [ :call, [ :var, "area_entities" ], [ [ :lit, String => a ] ] ] then [ @areas.fetch(a, a) ]
      in [ :op, "+", l, r ] then areas(l) + areas(r)
      else fail!
      end
    end

    def query_value(v)
      fail! if v.to_s.include?("'") || v.to_s.include?('"')
      v.to_s.include?(" ") ? "\"#{v}\"" : v.to_s
    end

    # ---- Liquid -----------------------------------------------------------------

    def liquid(node)
      case node
      in [ :op, "~", l, r ] then liquid(l) + liquid(r)
      in [ :lit, String => s ] then s.include?("{") ? fail! : s
      in [ :if, c, a, b ] then liquid_if(node, c, a, b)
      else "{{ #{liquid_value(node)} }}"
      end
    end

    # `a if c else b` no texto: pela conta quando dá; senão vira bloco `if`.
    def liquid_if(node, c, a, b)
      "{{ #{liquid_value(node)} }}"
    rescue Untranslatable
      "#{cond_open(c)}#{liquid(a)}{% else %}#{liquid(b)}{% endif %}"
    end

    def liquid_value(node)
      name, args = call_name(node)
      if (p = path(node)) then states_path(p, liquid: true) || variable(p, liquid: true)
      elsif name == "states" then "points[\"#{entity_ref(args[0])}\"].text"
      elsif name == "state_attr" && args.size == 2 then attr_ref(args, liquid: true)
      elsif %w[as_local as_datetime].include?(name) && args.size == 1 then liquid_value(args[0])
      elsif now_call?(node) then "now"
      elsif node in [ :call, [ :get, base, "strftime" ], [ [ :lit, String => fmt ] ] ] then "#{liquid_value(base)} | date: #{fmt.to_json}"
      elsif node in [ :call, [ :get, base, "isoformat" ], [] ] then "#{liquid_value(base)} | date: \"%Y-%m-%dT%H:%M:%S%:z\""
      elsif node in [ :call, [ :get, base, "split" ], [ [ :lit, String => sep ] ] ] then "#{liquid_value(base)} | split: #{sep.to_json}"
      elsif node in [ :index, base, [ :lit, Integer => i ] ] then liquid_index(base, i)
      elsif node in [ :slice, base, nil, [ :lit, Integer => n ] ] then "#{liquid_value(base)} | slice: 0, #{n}"
      elsif (node in [ :filter, name, x, args ]) && LIQUID_FILTERS.key?(name) && !(x in [ :lit, _ ])
        liquid_filter(name, liquid_value(x), args)
      else
        "#{quote(dentaku(node))} | calc"
      end
    end

    def liquid_index(base, i)
      return "#{liquid_value(base)} | first" if i.zero?
      return "#{liquid_value(base)} | last" if i == -1
      fail! if i.negative?

      "#{liquid_value(base)} | slice: #{i} | first"
    end

    def liquid_filter(name, base, args)
      lit = args.map { |a| (a in [ :lit, v ]) ? v.to_json : fail! }
      return base if name == "string"
      return "#{base} | #{LIQUID_FILTERS[name]}" if lit.empty? || name.in?(%w[int float count length trim lower upper sort first last])

      "#{base} | #{LIQUID_FILTERS[name]}: #{lit.join(', ')}"
    end
  end
end
