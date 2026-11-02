module Automations
  # Ações da DSL como plugins (Block). Tipo novo = classe (aqui ou em
  # automations/action_types/<nome>.rb) + nome em PLUGINS, com:
  #   call(engine, path, node) → [título, resultado, detalhe, checks] para o
  #     trace, ou [:halt] (parou/esperando) / [:skip] (sem passo no trace);
  #   compile(engine, node, path) só se precisar de saltos (se/escolher/repetir);
  #   commanded_point_ids(node, site, seen) se comandar pontos (papel x risco);
  #   shadow_safe?(engine, node) só se a ação puder rodar de verdade em sombra
  #     (F10): não sai nada para fora (aparelho, aviso, rede, IA paga). O
  #     padrão é falso (controle de fluxo é seguro): ação nova nasce segurada,
  #     roda como simulação (`dry_run?` verdadeiro) e vira "teria feito";
  #   shadow_effects(engine, node) → [{point_id, command, value}] do "teria
  #     feito" (padrão: os `commanded_point_ids` com o comando do nó).
  # O motor (Automations::Engine) expõe ao plugin: ctx, run, dry_run?,
  # conditions, trace, finish, suspend, suspend_wait_for, emit, program e compile.
  module ActionTypes
    extend Block::Registry

    PLUGINS = %w[CommandAction CommandQueryAction SceneAction ScriptAction NotifyAction SpeakAction WaitNotificationAction FireEventAction WaitEventAction HttpAction IntegrationReloadAction TraceNoteAction CalendarEventsAction WeatherForecastAction AiTaskAction AiDataAction SttAction TtsAction DatasetRecordAction DatasetQueryAction PointsHistoryAction
                 WaitAction WaitForAction
                 IfAction ChooseAction RepeatAction SetAction ConditionAction StopAction
                 ParallelAction SequenceAction SnapshotAction MqttPublishAction].freeze

    # Toda ação que faz algo (não as de controle) aceita "Seguir se der erro"
    # (Lote 1, `continue_on_error` do HA): a falha vira "erro tolerado" no trace.
    CONTINUE_ON_ERROR = Dsl.f("continue_on_error", :bool, "Seguir se der erro", en: "Continue on error", es: "Seguir si hay un error")
    # Contrato "toda ação pode devolver dados" (Lote 1, `response_variable` do
    # HA): o plugin declara `returns "formato"` e ganha o campo; o que ele passa
    # a `respond` vai para a variável, que o Liquid e as expressões das ações
    # seguintes leem (`resposta.status`, `{% for e in agenda.events %}`).
    RESPONSE_VARIABLE = Dsl.f("response_variable", :var, "Guardar a resposta em", en: "Save the response to", es: "Guardar la respuesta en")

    class Base < Block
      class << self
        def compile(engine, node, path) = engine.emit([ :act, path, node ])
        def call(_engine, _path, _node) = raise(NotImplementedError)
        def commanded_point_ids(_node, _site, _seen) = []
        def control? = false
        def shadow_safe?(_engine, _node) = control?

        def shadow_effects(e, node)
          commanded_point_ids(node, e.ctx.site, []).compact.map do |id|
            { "point_id" => e.ctx.point(id)&.id || id, "command" => node["command"], "value" => effect_value(e, node["value"]) }.compact
          end
        end

        # Lote 9: o "teria feito" guarda o valor resolvido (Liquid) e o ponto de campo ("$x"), como o comando real.
        def effect_value(e, value)
          Dsl.template?(value) ? e.ctx.render(value) : value
        rescue Context::Error
          value
        end

        # Formato da resposta (texto para a documentação e o editor); nil = não devolve.
        def returns(format = nil)
          @returns = format if format
          @returns && text(:returns, default: @returns)
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
               fields: [ f("point", :writable_point, "Ponto", required: true, en: "Point", es: "Punto"), f("command", :command, "Comando", required: true, en: "Command", es: "Comando"),
                         f("value", :value, "Valor (ajustar/selecionar)", en: "Value (set/select)", es: "Valor (ajustar/seleccionar)") ]
      texts en: { label: "Command a point" }, es: { label: "Enviar comando a un punto" }

      def self.commanded_point_ids(node, _site, _seen) = [ node["point"] ]

      # Helper que não comanda aparelho e ponto de script rodam na sombra.
      def self.shadow_safe?(e, node) = (p = e.ctx.point(node["point"])) ? Shadow.internal?(p) : false

      def self.call(e, _path, node)
        p = e.ctx.point(node["point"]) or raise Engine::Failure, "Ponto removido do local."
        arg = Dsl.template?(node["value"]) ? e.ctx.render(node["value"]) : node["value"] # Lote 7: valor por texto Liquid
        title = "#{Engine::COMMAND_LABELS.fetch(node['command'], node['command'])} #{p.name}#{" (#{arg})" unless arg.nil?}"
        if e.dry_run?
          value = Points::Command.new(p, node["command"].to_s, arg).new_value
          e.ctx.set_value(p, value)
          return [ title, "simulated", "Não enviado (simulação). Ficaria: #{e.ctx.point_text(p, value)}" ]
        end

        c = Points::Command.call(p, node["command"], arg, source: "automation", user: nil, run: e.run)
        raise Engine::Failure, "#{p.name}: #{c.error}" if c.status == "failed"

        [ title, "ok", "Comando #{c.status_label.downcase}" ]
      end
    end

    class SceneAction < Base
      describe key: "scene", label: "Acionar cena", fields: [ f("scene", :scene, "Cena", required: true, en: "Scene", es: "Escena") ]
      texts en: { label: "Activate scene" }, es: { label: "Activar escena" }

      def self.shadow_effects(e, node)
        scene = e.ctx.site.scenes.find_by(id: node["scene"]) or return []
        scene.items.map { |i| { "point_id" => i["point_id"], "command" => i["command"], "value" => i["value"] }.compact }
      end

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
               fields: [ f("script", :script, "Script", required: true, en: "Script", es: "Script"), f("fields", :script_fields, "Campos", en: "Fields", es: "Campos"),
                         f("wait", :bool, "Esperar o fim e a resposta", en: "Wait for it to finish and respond", es: "Esperar el final y la respuesta") ]
      returns "as variáveis do script no fim (com esperar)"
      texts "pt-BR" => { wait: "para guardar a resposta, marque esperar o fim." },
            en: { label: "Run script", returns: "the script's variables at the end (with wait)", wait: "to save the response, check wait for it to finish." },
            es: { label: "Ejecutar script", returns: "las variables del script al final (con esperar)", wait: "para guardar la respuesta, marca esperar el final." }

      def self.rules(node) = node["response_variable"].present? && node["wait"] != true ? [ text(:wait) ] : []

      # A execução do script herda a sombra de quem chamou (`cause`).
      def self.shadow_safe?(_e, _node) = true

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
               fields: [ f("for", :duration, "Tempo (ex.: 5m)", en: "Time (e.g. 5m)", es: "Tiempo (ej.: 5m)"),
                         f("expr", :expr, "Ou segundos por expressão", en: "Or seconds from an expression", es: "O segundos por expresión") ]
      texts "pt-BR" => { one: "informe o tempo ou a expressão." },
            en: { label: "Wait", one: "enter the time or the expression." }, es: { label: "Esperar", one: "indica el tiempo o la expresión." }

      def self.rules(node) = node["for"].nil? == node["expr"].nil? ? [ text(:one) ] : []

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
               fields: [ f("conditions", :conditions, "Até que", en: "Until", es: "Hasta que"),
                         f("timeout", :duration, "Tempo limite", required: true, en: "Timeout", es: "Tiempo límite"),
                         f("continue_on_timeout", :bool, "Seguir se o tempo acabar", en: "Continue if time runs out", es: "Seguir si se acaba el tiempo") ]
      texts en: { label: "Wait for condition" }, es: { label: "Esperar condición" }

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
               fields: [ f("conditions", :conditions, "Se", en: "If", es: "Si"), f("then", :actions, "Então", en: "Then", es: "Entonces"),
                         f("else", :actions, "Senão", en: "Else", es: "Si no") ]
      texts en: { label: "If / else" }, es: { label: "Si / si no" }

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
               fields: [ f("options", :options, "Opções", en: "Options", es: "Opciones"), f("default", :actions, "Se nenhuma servir", en: "If none match", es: "Si ninguna aplica") ]
      texts en: { label: "Choose" }, es: { label: "Elegir" }

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

      # Lote 5 (G22, `for_each` do HA): "para cada" item de uma lista, que é
      # uma variável (resposta de ação: `dados.rows`) ou itens separados por
      # vírgula; o item fica em `repeat_item` ({{ repeat.item }} no texto).
      describe key: "repeat", label: "Repetir", defaults: { "count" => 2 },
               fields: [ f("count", :number, "Vezes", en: "Times", es: "Veces"), f("while", :conditions, "Enquanto", en: "While", es: "Mientras"),
                         f("until", :conditions, "Até que", en: "Until", es: "Hasta que"),
                         f("for_each", :text, "Para cada (variável com lista ou itens separados por vírgula)", en: "For each (list variable or comma-separated items)", es: "Para cada (variable con lista o elementos separados por coma)"),
                         f("actions", :actions, "Fazer", en: "Do", es: "Hacer") ]
      texts "pt-BR" => { one: "informe vezes, enquanto, até que ou para cada (só um).", max: "no máximo %{max} vezes." },
            en: { label: "Repeat", one: "enter times, while, until or for each (only one).", max: "at most %{max} times." },
            es: { label: "Repetir", one: "indica veces, mientras, hasta que o para cada (solo uno).", max: "como máximo %{max} veces." }
      MODES = %w[count while until for_each].freeze

      # Itens do "para cada": a variável (lista) ou o texto dividido por vírgula.
      def self.items(ctx, node)
        ref = node["for_each"].to_s.strip
        head, *path = ref.split(".")
        list = ctx.vars.key?(head) && path.reduce(ctx.vars[head]) { |o, k| o.is_a?(Hash) ? o[k] : nil } if ref.match?(/\A[a-z_][a-z0-9_.]*\z/)
        list.is_a?(Array) ? list : ref.split(",").map(&:strip).compact_blank
      end

      def self.rules(node)
        msgs = []
        msgs << text(:one) if MODES.count { |k| node[k].present? } != 1
        msgs << text(:max, max: Dsl::MAX_REPEAT) if node["count"].is_a?(::Numeric) && !node["count"].between?(1, Dsl::MAX_REPEAT)
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
      def self.shadow_safe?(_e, _node) = true

      describe key: "set", label: "Definir variável",
               fields: [ f("var", :var, "Nome", required: true, en: "Name", es: "Nombre"),
                         f("expr", :expr, "Expressão (número/lógica)", en: "Expression (number/logic)", es: "Expresión (número/lógica)"),
                         f("value", :prompt, "Ou texto", en: "Or text", es: "O texto") ]
      texts "pt-BR" => { one: "informe a expressão ou o texto." },
            en: { label: "Set variable", one: "enter the expression or the text." }, es: { label: "Definir variable", one: "indica la expresión o el texto." }

      def self.rules(node) = node["expr"].nil? == node["value"].nil? ? [ text(:one) ] : []

      def self.call(e, _path, node)
        v = node.key?("expr") ? e.ctx.calc(node["expr"]) : e.ctx.render(node["value"])
        e.ctx.vars[node["var"]] = v
        [ "#{node['var']} = #{v.inspect.truncate(80)}", "ok" ]
      end
    end

    class ConditionAction < Base
      def self.control? = true

      describe key: "condition", label: "Parar se falso", fields: [ f("conditions", :conditions, "Seguir só se", en: "Continue only if", es: "Seguir solo si") ]
      texts en: { label: "Stop if false" }, es: { label: "Detener si es falso" }

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

      describe key: "stop", label: "Parar", fields: [ f("reason", :text, "Motivo", en: "Reason", es: "Motivo"), f("error", :bool, "Marcar como erro", en: "Mark as error", es: "Marcar como error") ]
      texts en: { label: "Stop" }, es: { label: "Detener" }

      def self.call(e, path, node)
        e.trace(path, "stop", "Parar#{": #{node['reason']}" if node['reason'].present?}", node["error"] ? "error" : "ok")
        e.finish(node["error"] ? "failed" : "stopped", node["reason"].presence)
        [ :halt ]
      end
    end
  end
end
