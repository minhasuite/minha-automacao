module Automations
  # Executa as ações de uma AutomationRun. A árvore de ações vira um programa
  # plano (com saltos para se/escolher/repetir), então "onde parou" é só o
  # contador de programa + variáveis + contadores de repetição, guardados em
  # `run.state`. Espera = grava o estado e agenda o AutomationResumeJob no
  # Solid Queue (sobrevive a reinício; nada de `sleep`). `seq` muda a cada
  # espera: job velho ou repetido não retoma.
  #
  # Simulação (`dry_run`): comando não sai (o valor hipotético muda), aviso
  # não é enviado, espera não espera e "esperar condição" que não se cumpre
  # segue pelo tempo limite. O trace mostra o que aconteceria.
  class Engine
    class Failure < StandardError; end

    MAX_STEPS = 1000
    MAX_TRACE = 300
    # "Esperar condição" sem ponto que avise (horário, sol) olha de novo nesse intervalo.
    WAIT_POLL = 1.minute

    COMMAND_LABELS = Points::Timeline::COMMAND_LABELS

    def self.start(run, definition, ctx, skip_conditions: false) = new(run, definition, ctx).start(skip_conditions)

    # Retomada pelo job (`seq`) ou pela mudança de um ponto (`seq` nil: só
    # "esperar condição", e só se ela já vale).
    def self.resume(run, seq = nil)
      state = run.state
      return unless run.status == "waiting" && (seq.nil? || state["seq"] == seq)
      return if seq.nil? && state.dig("wait", "kind") != "wait_for"

      ctx = Context.new(site: run.site, trigger: run.trigger, vars: state["vars"])
      new(run, run.automation.definition_for(run.version), ctx).resume(seq.nil?)
    end

    def initialize(run, definition, ctx)
      @run = run
      @definition = definition
      @ctx = ctx
      @conditions = Conditions.new(ctx)
      @program = []
      compile(definition["actions"], "actions")
      state = run.state
      @pc = state["pc"].to_i
      @counters = state["counters"] || {}
      @seq = state["seq"].to_i
    end

    def start(skip_conditions)
      within do
        conds = Array(@definition["conditions"])
        if skip_conditions
          trace("conditions", "conditions", "Condições ignoradas (executar agora)", "skipped") if conds.any?
        elsif conds.any?
          ok, checks = @conditions.check(conds)
          trace("conditions", "conditions", ok ? "Condições atendidas" : "Condições não atendidas", ok ? "ok" : "false", checks: checks)
          next finish("skipped") unless ok
        end
        run_program
      end
    end

    def resume(by_event)
      wait = @run.state["wait"] || {}
      if wait["kind"] == "wait_for"
        node = node_at(wait["path"])
        ok, checks = @conditions.check(node["conditions"])
        timeout = !ok && Time.current >= Time.zone.parse(wait["deadline"])
        return if by_event && !ok
        return claim && suspend_wait_for(wait["path"], node, Time.zone.parse(wait["deadline"])) unless ok || timeout
        return unless claim

        within do
          close_wait(ok ? "ok" : "timeout")
          trace(wait["path"], "wait", ok ? "Condição atendida, seguindo" : "Tempo limite da espera", ok ? "ok" : "timeout", checks: checks)
          next finish("stopped", "Tempo limite da espera") if timeout && node["continue_on_timeout"] == false

          run_program
        end
      else
        return unless claim

        within do
          close_wait("ok")
          run_program
        end
      end
    end

    private

    # Muda waiting → running de forma atômica (job e evento ao mesmo tempo:
    # só um retoma).
    def claim
      return false unless AutomationRun.where(id: @run.id, status: "waiting").update_all(status: "running", updated_at: Time.current) == 1 # rubocop:disable Rails/SkipsModelValidations

      @run.reload
      true
    end

    # Marca a execução corrente na thread (laço de pontos virtuais em cadeia)
    # e transforma erro em execução com falha.
    def within
      previous = Thread.current[:automation_run]
      Thread.current[:automation_run] = @run
      yield
    rescue Failure, Points::Command::Error, Context::Error => e
      trace("error", "error", "Erro", "error", detail: e.message)
      finish("failed", e.message)
    rescue StandardError => e
      Rails.error.report(e, handled: true)
      trace("error", "error", "Erro interno", "error", detail: e.message.truncate(200))
      finish("failed", e.message.truncate(200))
    ensure
      Thread.current[:automation_run] = previous
    end

    # ---- compilação ----------------------------------------------------------

    def emit(op)
      @program << op
      @program.size - 1
    end

    def compile(actions, path)
      Array(actions).each_with_index do |a, i|
        p = "#{path}.#{i}"
        case a["type"]
        when "if" then compile_if(a, p)
        when "choose" then compile_choose(a, p)
        when "repeat"
          emit([ :rep_init, p ])
          start = emit([ :rep_check, p, a, nil ])
          compile(a["actions"], "#{p}.actions")
          emit([ :jmp, start ])
          @program[start][3] = @program.size
        else emit([ :act, p, a ])
        end
      end
    end

    def compile_if(a, p)
      branch = emit([ :branch, p, a["conditions"], nil, "Se" ])
      compile(a["then"], "#{p}.then")
      if Array(a["else"]).any?
        jump = emit([ :jmp, nil ])
        @program[branch][3] = @program.size
        compile(a["else"], "#{p}.else")
        @program[jump][1] = @program.size
      else
        @program[branch][3] = @program.size
      end
    end

    def compile_choose(a, p)
      ends = Array(a["options"]).each_with_index.map do |o, n|
        branch = emit([ :branch, "#{p}.options.#{n}", o["conditions"], nil, "Opção #{n + 1}" ])
        compile(o["actions"], "#{p}.options.#{n}.actions")
        jump = emit([ :jmp, nil ])
        @program[branch][3] = @program.size
        jump
      end
      compile(a["default"], "#{p}.default")
      ends.each { |j| @program[j][1] = @program.size }
    end

    def node_at(path) = @program.find { |op| op[0] == :act && op[1] == path }&.dig(2) || raise(Failure, "A espera não existe mais nesta versão.")

    # ---- execução ------------------------------------------------------------

    def run_program
      count = 0
      while @pc < @program.size
        raise Failure, "Passos demais (#{MAX_STEPS}): laço sem fim?" if (count += 1) > MAX_STEPS

        op = @program[@pc]
        @pc += 1
        case op[0]
        when :jmp then @pc = op[1]
        when :branch
          ok, checks = @conditions.check(op[2])
          trace(op[1], "branch", "#{op[4]}: #{ok ? 'sim' : 'não'}", ok ? "ok" : "false", checks: checks)
          @pc = op[3] unless ok
        when :rep_init then @counters[op[1]] = 0
        when :rep_check then repeat(op)
        when :act then return if act(op[1], op[2]) == :halt
        end
      end
      finish("done")
    end

    def repeat(op)
      path, node, finish_at = op[1..]
      n = @counters[path] = @counters[path].to_i + 1
      done, checks = repeat_done(node, n)
      limit = !done && n > Dsl::MAX_REPEAT
      if done || limit
        trace(path, "repeat", limit ? "Repetir: parou no limite de #{Dsl::MAX_REPEAT} voltas" : "Repetir: fim (#{n - 1} voltas)", "ok", checks: checks)
        @pc = finish_at
      else
        @ctx.vars["repeat_index"] = n
        trace(path, "repeat", "Repetir: volta #{n}", "ok", checks: checks)
      end
    end

    # [acabou?, checks]: vezes, enquanto (antes de cada volta) ou até que
    # (depois de cada volta).
    def repeat_done(node, n)
      return [ n > node["count"], nil ] if node["count"]

      if node["while"]
        ok, checks = @conditions.check(node["while"])
        return [ !ok, checks ]
      end
      n > 1 ? @conditions.check(node["until"]) : [ false, nil ]
    end

    def act(path, node)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      title, result, detail, checks = send(:"act_#{node['type']}", path, node)
      return :halt if title == :halt
      return if title == :skip

      trace(path, node["type"], title, result, detail: detail, checks: checks, ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round)
    end

    def act_command(_path, node)
      p = @ctx.point(node["point"]) or raise Failure, "Ponto removido do local."
      title = "#{COMMAND_LABELS.fetch(node['command'], node['command'])} #{p.name}#{" (#{node['value']})" unless node['value'].nil?}"
      if dry_run?
        value = Points::Command.new(p, node["command"].to_s, node["value"]).new_value
        @ctx.set_value(p, value)
        return [ title, "simulated", "Não enviado (simulação). Ficaria: #{@ctx.point_text(p, value)}" ]
      end

      c = Points::Command.call(p, node["command"], node["value"], source: "automation", user: nil, run: @run)
      raise Failure, "#{p.name}: #{c.error}" if c.status == "failed"

      [ title, "ok", "Comando #{c.status_label.downcase}" ]
    end

    def act_scene(_path, node)
      scene = @ctx.site.scenes.find_by(id: node["scene"]) or raise Failure, "Cena removida do local."
      return [ "Acionar cena #{scene.name}", "simulated", "Não acionada (simulação): #{scene.items.size} comandos" ] if dry_run?

      commands, failures = scene.activate!(source: "automation", user: nil)
      [ "Acionar cena #{scene.name}", failures.any? ? "error" : "ok", [ "#{commands.size} comandos", *failures ].join(" · ") ]
    end

    def act_notify(_path, node)
      title = @ctx.render(node["title"])
      body = @ctx.render(node["message"]).presence
      channels = node["channels"].presence || Notifier::CHANNELS.keys
      detail = [ body, "canais: #{channels.map { |ch| Notifier::CHANNELS.fetch(ch, ch) }.join(', ').downcase}" ].compact.join(" · ")
      return [ "Avisar: #{title}", "simulated", "Não enviado (simulação). #{detail}" ] if dry_run?

      Notifier.deliver!(channels, kind: "automacao", title: title, body: body,
                                  data: { automation_id: @run.automation_id, run_id: @run.id, site_id: @run.site_id })
      [ "Avisar: #{title}", "ok", detail ]
    end

    def act_set(_path, node)
      v = node.key?("expr") ? @ctx.calc(node["expr"]) : @ctx.render(node["value"])
      @ctx.vars[node["var"]] = v
      [ "#{node['var']} = #{v.inspect.truncate(80)}", "ok" ]
    end

    def act_stop(path, node)
      trace(path, "stop", "Parar#{": #{node['reason']}" if node['reason'].present?}", node["error"] ? "error" : "ok")
      finish(node["error"] ? "failed" : "stopped", node["reason"].presence)
      [ :halt ]
    end

    def act_condition(path, node)
      ok, checks = @conditions.check(node["conditions"])
      return [ "Seguir só se: sim", "ok", nil, checks ] if ok

      trace(path, "condition", "Seguir só se: não, parou aqui", "false", checks: checks)
      finish("stopped", nil)
      [ :halt ]
    end

    def act_wait(path, node)
      sec = node.key?("for") ? Dsl.seconds(node["for"]) : @ctx.calc(node["expr"]).to_f.round
      sec = sec.to_i.clamp(0, Dsl::MAX_DURATION)
      label = "Esperar #{Dsl.duration_label(sec)}"
      return [ label, "simulated", "Não esperou (simulação)." ] if dry_run? || sec.zero?

      until_at = Time.current + sec
      trace(path, "wait", label, "waiting", detail: "até #{I18n.l(until_at.in_time_zone(@ctx.now.time_zone), format: '%d/%m %H:%M:%S')}")
      suspend(until_at, "kind" => "wait", "path" => path)
      [ :halt ]
    end

    def act_wait_for(path, node)
      ok, checks = @conditions.check(node["conditions"])
      timeout = Dsl.seconds(node["timeout"]).to_i
      return [ "Esperar condição: já atendida", "ok", nil, checks ] if ok

      if dry_run?
        stop = node["continue_on_timeout"] == false
        trace(path, "wait_for", "Esperar condição: não se cumpre na simulação", "timeout",
              detail: "Seguiria após #{Dsl.duration_label(timeout)}#{' parando aqui' if stop}.", checks: checks)
        return [ :halt ].tap { finish("stopped", "Tempo limite da espera") } if stop

        return [ :skip ]
      end

      trace(path, "wait_for", "Esperar condição (até #{Dsl.duration_label(timeout)})", "waiting", checks: checks)
      suspend_wait_for(path, node, Time.current + timeout)
      [ :halt ]
    end

    def suspend_wait_for(path, _node, deadline)
      at = [ deadline, @ctx.recheck_at, Time.current + WAIT_POLL ].compact.min
      suspend(at, "kind" => "wait_for", "path" => path, "deadline" => deadline.iso8601(3))
    end

    def suspend(resume_at, wait)
      @seq += 1
      save(status: "waiting", resume_at: resume_at, wait: wait)
      AutomationResumeJob.set(wait_until: resume_at).perform_later(@run.id, @seq)
      :halt
    end

    def finish(status, error = nil)
      return :halt if @run.finished_at

      save(status: status, error: error&.truncate(255), finished_at: Time.current, resume_at: nil)
      @run.automation.after_run(@run) unless dry_run?
      :halt
    end

    def save(wait: nil, **attrs)
      @run.update!(attrs.merge(state: { "pc" => @pc, "vars" => @ctx.vars, "counters" => @counters, "seq" => @seq, "wait" => wait }.compact))
    end

    def trace(path, kind, title, result, detail: nil, checks: nil, ms: nil)
      return if @run.steps.size > MAX_TRACE
      return @run.steps << { "kind" => "truncated", "title" => "Trace cortado em #{MAX_TRACE} passos", "result" => "ok" } if @run.steps.size == MAX_TRACE

      @run.steps << { "at" => Time.current.iso8601(3), "path" => path, "kind" => kind, "title" => title, "result" => result,
                      "detail" => detail, "checks" => checks, "ms" => ms }.compact
    end

    def close_wait(result)
      step = @run.steps.reverse.find { |s| s["result"] == "waiting" }
      step["result"] = result if step
    end

    def dry_run? = @run.dry_run
  end
end
