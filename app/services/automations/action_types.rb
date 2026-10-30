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

    PLUGINS = %w[CommandAction SceneAction ScriptAction NotifyAction WaitAction WaitForAction IfAction ChooseAction RepeatAction
                 SetAction ConditionAction StopAction].freeze

    class Base < Block
      class << self
        def compile(engine, node, path) = engine.emit([ :act, path, node ])
        def call(_engine, _path, _node) = raise(NotImplementedError)
        def commanded_point_ids(_node, _site, _seen) = []
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
    class ScriptAction < Base
      describe key: "script", label: "Executar script",
               fields: [ f("script", :script, "Script", required: true), f("fields", :script_fields, "Campos") ]

      def self.commanded_point_ids(node, site, seen)
        script = site.scripts.find_by(id: node["script"]) if node["script"].is_a?(String)
        return [] if script.nil? || seen.include?(script.id)

        seen << script.id
        Dsl.commanded_points(script.definition, site, seen).map(&:id) + script.point_field_values(node["fields"])
      end

      def self.call(e, _path, node)
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

        [ title, "ok", [ "Execução #{run.status_label.downcase}", detail ].compact.join(" · ") ]
      rescue ArgumentError => ex
        raise Engine::Failure, "Script: #{ex.message}"
      end
    end

    class NotifyAction < Base
      describe key: "notify", label: "Avisar", defaults: { "channels" => Notifier::CHANNELS.keys, "title" => "Aviso" },
               fields: [ f("channels", :channels, "Canais"), f("title", :template, "Título", required: true), f("message", :template, "Mensagem") ]

      def self.call(e, _path, node)
        title = e.ctx.render(node["title"])
        body = e.ctx.render(node["message"]).presence
        channels = node["channels"].presence || Notifier::CHANNELS.keys
        detail = [ body, "canais: #{channels.map { |ch| Notifier.channel_label(ch) }.join(', ').downcase}" ].compact.join(" · ")
        return [ "Avisar: #{title}", "simulated", "Não enviado (simulação). #{detail}" ] if e.dry_run?

        r = e.run
        Notifier.deliver!(channels, kind: "automacao", title: title, body: body, data: { automation_id: r.automation_id, run_id: r.id, site_id: r.site_id })
        [ "Avisar: #{title}", "ok", detail ]
      end
    end

    class WaitAction < Base
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
      describe key: "stop", label: "Parar", fields: [ f("reason", :text, "Motivo"), f("error", :bool, "Marcar como erro") ]

      def self.call(e, path, node)
        e.trace(path, "stop", "Parar#{": #{node['reason']}" if node['reason'].present?}", node["error"] ? "error" : "ok")
        e.finish(node["error"] ? "failed" : "stopped", node["reason"].presence)
        [ :halt ]
      end
    end
  end
end
