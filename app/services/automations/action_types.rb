module Automations
  # Ações da DSL como plugins (Block). Tipo novo = classe (aqui ou em
  # automations/action_types/<nome>.rb) + nome em PLUGINS, com:
  #   call(engine, path, node) → [título, resultado, detalhe, checks] para o
  #     trace, ou [:halt] (parou/esperando) / [:skip] (sem passo no trace);
  #   compile(engine, node, path) só se precisar de saltos (se/escolher/repetir);
  #   commanded_point_ids(node, site, seen) se comandar pontos (papel x risco).
  # O motor (Automations::Engine) expõe ao plugin: ctx, run, dry_run?,
  # conditions, trace, finish, suspend, suspend_wait_for, emit, program e compile.
  module ActionTypes
    extend Block::Registry

    PLUGINS = %w[CommandAction SceneAction ScriptAction NotifyAction SpeakAction WaitNotificationAction HttpAction CalendarEventsAction WeatherForecastAction AiTaskAction AiDataAction DatasetRecordAction DatasetQueryAction
                 WaitAction WaitForAction
                 IfAction ChooseAction RepeatAction SetAction ConditionAction StopAction].freeze

    # Toda ação que faz algo (não as de controle) aceita "Seguir se der erro"
    # (Lote 1, `continue_on_error` do HA): a falha vira "erro tolerado" no trace.
    CONTINUE_ON_ERROR = Dsl.f("continue_on_error", :bool, "Seguir se der erro")
    # Contrato "toda ação pode devolver dados" (Lote 1, `response_variable` do
    # HA): o plugin declara `returns "formato"` e ganha o campo; o que ele passa
    # a `respond` vai para a variável, que o Liquid e as expressões das ações
    # seguintes leem (`resposta.status`, `{% for e in agenda.events %}`).
    RESPONSE_VARIABLE = Dsl.f("response_variable", :var, "Guardar a resposta em")

    class Base < Block
      class << self
        def compile(engine, node, path) = engine.emit([ :act, path, node ])
        def call(_engine, _path, _node) = raise(NotImplementedError)
        def commanded_point_ids(_node, _site, _seen) = []
        def control? = false

        # Formato da resposta (texto para a documentação e o editor); nil = não devolve.
        def returns(format = nil)
          @returns = format if format
          @returns
        end

        def fields
          list = super
          list += [ RESPONSE_VARIABLE ] if returns
          list += [ CONTINUE_ON_ERROR ] unless control?
          list
        end

        def respond(e, node, value)
          e.ctx.vars[node["response_variable"]] = value if node["response_variable"].present?
        end
      end
    end

    class CommandAction < Base
      describe key: "command", label: "Comandar ponto", defaults: { "command" => "on" },
               fields: [ f("point", :writable_point, "Ponto", required: true), f("command", :command, "Comando", required: true),
                         f("value", :value, "Valor (ajustar/selecionar)") ]

      def self.commanded_point_ids(node, _site, _seen) = [ node["point"] ]

      def self.call(e, _path, node)
        p = e.ctx.point(node["point"]) or raise Engine::Failure, "Ponto removido do local."
        title = "#{Engine::COMMAND_LABELS.fetch(node['command'], node['command'])} #{p.name}#{" (#{node['value']})" unless node['value'].nil?}"
        if e.dry_run?
          value = Points::Command.new(p, node["command"].to_s, node["value"]).new_value
          e.ctx.set_value(p, value)
          return [ title, "simulated", "Não enviado (simulação). Ficaria: #{e.ctx.point_text(p, value)}" ]
        end

        c = Points::Command.call(p, node["command"], node["value"], source: "automation", user: nil, run: e.run)
        raise Engine::Failure, "#{p.name}: #{c.error}" if c.status == "failed"

        [ title, "ok", "Comando #{c.status_label.downcase}" ]
      end
    end

    class SceneAction < Base
      describe key: "scene", label: "Acionar cena", fields: [ f("scene", :scene, "Cena", required: true) ]

      def self.call(e, _path, node)
        scene = e.ctx.site.scenes.find_by(id: node["scene"]) or raise Engine::Failure, "Cena removida do local."
        return [ "Acionar cena #{scene.name}", "simulated", "Não acionada (simulação): #{scene.items.size} comandos" ] if e.dry_run?

        commands, failures = scene.activate!(source: "automation", user: nil)
        [ "Acionar cena #{scene.name}", failures.any? ? "error" : "ok", [ "#{commands.size} comandos", *failures ].join(" · ") ]
      end
    end

    # Chama um script do local com os campos (F8f). O script roda como
    # execução própria (trace dele), ligada a esta pela causa (laço evitado).
    # Lote 1: com "esperar", a automação só segue quando o script termina e a
    # resposta (as variáveis do script no fim) vai para `response_variable`;
    # sem, dispara e não espera (como antes).
    class ScriptAction < Base
      describe key: "script", label: "Executar script",
               fields: [ f("script", :script, "Script", required: true), f("fields", :script_fields, "Campos"),
                         f("wait", :bool, "Esperar o fim e a resposta") ]
      returns "as variáveis do script no fim (com esperar)"

      def self.rules(node) = node["response_variable"].present? && node["wait"] != true ? [ "para guardar a resposta, marque esperar o fim." ] : []

      def self.commanded_point_ids(node, site, seen)
        script = site.scripts.find_by(id: node["script"]) if node["script"].is_a?(String)
        return [] if script.nil? || seen.include?(script.id)

        seen << script.id
        Dsl.commanded_points(script.definition, site, seen).map(&:id) + script.point_field_values(node["fields"])
      end

      def self.call(e, path, node)
        script = e.ctx.site.scripts.find_by(id: node["script"]) or raise Engine::Failure, "Script removido do local."
        given = node["fields"].to_h.transform_values { |v| v.is_a?(String) && v.include?("{{") ? e.ctx.render(v) : v }
        values = script.field_values(given)
        title = "Executar script #{script.name}"
        detail = values.map { |k, v| "#{k}: #{v}" }.join(", ").presence
        return [ title, "simulated", [ "Não executado (simulação)", detail ].compact.join(". ") ] if e.dry_run?

        run = script.run_script!(values, title: "Chamado por #{e.run.automation.name}", cause: e.run)
        return [ title, "skipped", "Não iniciou: já está rodando (#{script.mode_label.split(' (').first.downcase})" ] unless run
        return [ title, "skipped", run.error ] if run.status == "loop"
        raise Engine::Failure, "Script #{script.name}: #{run.error}" if run.status == "failed"
        return wait_for_script(e, path, node, script, run, title) if node["wait"] == true && !run.finished?

        respond(e, node, run.response) if node["wait"] == true
        [ title, "ok", [ "Execução #{run.status_label.downcase}", detail ].compact.join(" · ") ]
      rescue ArgumentError => ex
        raise Engine::Failure, "Script: #{ex.message}"
      end

      # O script ficou esperando (ou na fila): esta execução espera o evento
      # "script_finished" dele, sem prazo além do máximo da DSL.
      def self.wait_for_script(e, path, node, script, run, title)
        e.trace(path, "script", title, "waiting", detail: "Esperando o script terminar")
        e.suspend(Time.current + Dsl::MAX_DURATION, "kind" => "event", "event" => "script_finished", "match" => { "run_id" => run.id },
                                                    "path" => path, "var" => node["response_variable"], "key" => "response",
                                                    "got" => "Script #{script.name} terminou", "stop_on_timeout" => true)
        [ :halt ]
      end
    end

    class WaitAction < Base
      def self.control? = true

      describe key: "wait", label: "Esperar", defaults: { "for" => "1m" },
               fields: [ f("for", :duration, "Tempo (ex.: 5m)"), f("expr", :expr, "Ou segundos por expressão") ]

      def self.rules(node) = node["for"].nil? == node["expr"].nil? ? [ "informe o tempo ou a expressão." ] : []

      def self.call(e, path, node)
        sec = node.key?("for") ? Dsl.seconds(node["for"]) : e.ctx.calc(node["expr"]).to_f.round
        sec = sec.to_i.clamp(0, Dsl::MAX_DURATION)
        label = "Esperar #{Dsl.duration_label(sec)}"
        return [ label, "simulated", "Não esperou (simulação)." ] if e.dry_run? || sec.zero?

        until_at = Time.current + sec
        e.trace(path, "wait", label, "waiting", detail: "até #{I18n.l(until_at.in_time_zone(e.ctx.now.time_zone), format: '%d/%m %H:%M:%S')}")
        e.suspend(until_at, "kind" => "wait", "path" => path)
        [ :halt ]
      end
    end

    class WaitForAction < Base
      def self.control? = true

      describe key: "wait_for", label: "Esperar condição", defaults: { "conditions" => [], "timeout" => "5m" },
               fields: [ f("conditions", :conditions, "Até que"), f("timeout", :duration, "Tempo limite", required: true),
                         f("continue_on_timeout", :bool, "Seguir se o tempo acabar") ]

      def self.call(e, path, node)
        ok, checks = e.conditions.check(node["conditions"])
        timeout = Dsl.seconds(node["timeout"]).to_i
        return [ "Esperar condição: já atendida", "ok", nil, checks ] if ok

        if e.dry_run?
          stop = node["continue_on_timeout"] == false
          e.trace(path, "wait_for", "Esperar condição: não se cumpre na simulação", "timeout",
                  detail: "Seguiria após #{Dsl.duration_label(timeout)}#{' parando aqui' if stop}.", checks: checks)
          return [ :halt ].tap { e.finish("stopped", "Tempo limite da espera") } if stop

          return [ :skip ]
        end

        e.trace(path, "wait_for", "Esperar condição (até #{Dsl.duration_label(timeout)})", "waiting", checks: checks)
        e.suspend_wait_for(path, Time.current + timeout)
        [ :halt ]
      end
    end

    class IfAction < Base
      def self.control? = true

      describe key: "if", label: "Se / senão",
               fields: [ f("conditions", :conditions, "Se"), f("then", :actions, "Então"), f("else", :actions, "Senão") ]

      def self.compile(e, a, p)
        branch = e.emit([ :branch, p, a["conditions"], nil, "Se" ])
        e.compile(a["then"], "#{p}.then")
        if Array(a["else"]).any?
          jump = e.emit([ :jmp, nil ])
          e.program[branch][3] = e.program.size
          e.compile(a["else"], "#{p}.else")
          e.program[jump][1] = e.program.size
        else
          e.program[branch][3] = e.program.size
        end
      end
    end

    class ChooseAction < Base
      def self.control? = true

      describe key: "choose", label: "Escolher", defaults: { "options" => [ { "conditions" => [], "actions" => [] } ] },
               fields: [ f("options", :options, "Opções"), f("default", :actions, "Se nenhuma servir") ]

      def self.compile(e, a, p)
        ends = Array(a["options"]).each_with_index.map do |o, n|
          branch = e.emit([ :branch, "#{p}.options.#{n}", o["conditions"], nil, "Opção #{n + 1}" ])
          e.compile(o["actions"], "#{p}.options.#{n}.actions")
          jump = e.emit([ :jmp, nil ])
          e.program[branch][3] = e.program.size
          jump
        end
        e.compile(a["default"], "#{p}.default")
        ends.each { |j| e.program[j][1] = e.program.size }
      end
    end

    class RepeatAction < Base
      def self.control? = true

      describe key: "repeat", label: "Repetir", defaults: { "count" => 2 },
               fields: [ f("count", :number, "Vezes"), f("while", :conditions, "Enquanto"), f("until", :conditions, "Até que"),
                         f("actions", :actions, "Fazer") ]

      def self.rules(node)
        msgs = []
        msgs << "informe vezes, enquanto ou até que (só um)." if %w[count while until].count { |k| node[k].present? } != 1
        msgs << "no máximo #{Dsl::MAX_REPEAT} vezes." if node["count"].is_a?(::Numeric) && !node["count"].between?(1, Dsl::MAX_REPEAT)
        msgs
      end

      def self.compile(e, a, p)
        e.emit([ :rep_init, p ])
        start = e.emit([ :rep_check, p, a, nil ])
        e.compile(a["actions"], "#{p}.actions")
        e.emit([ :jmp, start ])
        e.program[start][3] = e.program.size
      end
    end

    class SetAction < Base
      describe key: "set", label: "Definir variável",
               fields: [ f("var", :var, "Nome", required: true), f("expr", :expr, "Expressão (número/lógica)"), f("value", :template, "Ou texto") ]

      def self.rules(node) = node["expr"].nil? == node["value"].nil? ? [ "informe a expressão ou o texto." ] : []

      def self.call(e, _path, node)
        v = node.key?("expr") ? e.ctx.calc(node["expr"]) : e.ctx.render(node["value"])
        e.ctx.vars[node["var"]] = v
        [ "#{node['var']} = #{v.inspect.truncate(80)}", "ok" ]
      end
    end

    class ConditionAction < Base
      def self.control? = true

      describe key: "condition", label: "Parar se falso", fields: [ f("conditions", :conditions, "Seguir só se") ]

      def self.call(e, path, node)
        ok, checks = e.conditions.check(node["conditions"])
        return [ "Seguir só se: sim", "ok", nil, checks ] if ok

        e.trace(path, "condition", "Seguir só se: não, parou aqui", "false", checks: checks)
        e.finish("stopped", nil)
        [ :halt ]
      end
    end

    class StopAction < Base
      def self.control? = true

      describe key: "stop", label: "Parar", fields: [ f("reason", :text, "Motivo"), f("error", :bool, "Marcar como erro") ]

      def self.call(e, path, node)
        e.trace(path, "stop", "Parar#{": #{node['reason']}" if node['reason'].present?}", node["error"] ? "error" : "ok")
        e.finish(node["error"] ? "failed" : "stopped", node["reason"].presence)
        [ :halt ]
      end
    end
  end
end
