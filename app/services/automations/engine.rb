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

    # Evento esperado chegou (espera "event": resposta de aviso, fim de
    # script). `match`: cada chave precisa bater (lista = qualquer um dela).
    def self.resume_event(run, payload)
      wait = run.state["wait"] || {}
      return unless run.status == "waiting" && wait["kind"] == "event" && match?(wait["match"], payload)

      ctx = Context.new(site: run.site, trigger: run.trigger, vars: run.state["vars"])
      new(run, run.automation.definition_for(run.version), ctx).resume_with(payload)
    end

    def self.match?(filter, payload) = filter.to_h.all? { |k, v| v.blank? || Array(v).include?(payload[k]) }

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
      return resume_with(nil) if wait["kind"] == "event" # tempo limite

      if wait["kind"] == "wait_for"
        node = node_at(wait["path"])
        ok, checks = @conditions.check(node["conditions"])
        timeout = !ok && Time.current >= Time.zone.parse(wait["deadline"])
        return if by_event && !ok
        return claim && suspend_wait_for(wait["path"], Time.zone.parse(wait["deadline"])) unless ok || timeout
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

    # Retoma a espera "event": com os dados do evento ou, sem eles (nil), pelo
    # tempo limite. A variável `var` da espera recebe os dados (ou `key` deles;
    # nil no tempo limite). Dados com `error` (script que falhou) viram falha.
    def resume_with(payload)
      return unless claim

      wait = @run.state["wait"] || {}
      within do
        @ctx.vars[wait["var"]] = payload && (wait["key"] ? payload[wait["key"]] : payload) if wait["var"].present?
        close_wait(payload ? "ok" : "timeout")
        trace(wait["path"], "wait", payload ? wait["got"] || "Evento recebido" : "Tempo limite da espera", payload ? "ok" : "timeout",
              detail: (payload && wait["detail"] ? payload[wait["detail"]] : nil))
        raise Failure, payload["error"] if payload && payload["error"].present?
        next finish("stopped", "Tempo limite da espera") if payload.nil? && wait["stop_on_timeout"]

        run_program
      end
    end

    # ---- para os plugins de ação ----------------------------------------------

    attr_reader :ctx, :conditions, :program, :run

    def dry_run? = @run.dry_run

    # ---- compilação (os plugins de ActionTypes emitem os passos) -------------

    def emit(op)
      @program << op
      @program.size - 1
    end

    def compile(actions, path)
      Array(actions).each_with_index do |a, i|
        plugin = ActionTypes[a["type"]] or raise Failure, "Ação desconhecida: #{a['type']}"
        plugin.compile(self, a, "#{path}.#{i}")
      end
    end

    def suspend_wait_for(path, deadline)
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
      unless dry_run?
        @run.automation.after_run(@run)
        # Quem chamou o script e espera a resposta (ação "Executar script" com esperar).
        if @run.automation.script?
          Triggers.event(@run.site_id, "script_finished", { "run_id" => @run.id, "status" => status, "response" => @run.response,
                                                            "error" => (error.presence || "parou sem concluir" if status == "failed") }.compact)
        end
      end
      :halt
    end

    def trace(path, kind, title, result, detail: nil, checks: nil, ms: nil)
      return if @run.steps.size > MAX_TRACE
      return @run.steps << { "kind" => "truncated", "title" => "Trace cortado em #{MAX_TRACE} passos", "result" => "ok" } if @run.steps.size == MAX_TRACE

      @run.steps << { "at" => Time.current.iso8601(3), "path" => path, "kind" => kind, "title" => title, "result" => result,
                      "detail" => detail, "checks" => checks, "ms" => ms }.compact
    end

    private

    def node_at(path) = @program.find { |op| op[0] == :act && op[1] == path }&.dig(2) || raise(Failure, "A espera não existe mais nesta versão.")

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
      title, result, detail, checks = call_action(path, node)
      return :halt if title == :halt
      return if title == :skip

      trace(path, node["type"], title, result, detail: detail, checks: checks, ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round)
    end

    # `continue_on_error` (Lote 1): a falha da ação fica no trace como "erro
    # tolerado" e a execução segue.
    def call_action(path, node)
      plugin = ActionTypes[node["type"]]
      plugin.call(self, path, node)
    rescue Failure, Points::Command::Error, Context::Error, StandardError => e
      raise unless node["continue_on_error"] == true

      Rails.error.report(e, handled: true) unless e.is_a?(Failure) || e.is_a?(Points::Command::Error) || e.is_a?(Context::Error)
      [ "#{plugin.label}: erro tolerado", "tolerated", e.message.truncate(200) ]
    end

    def save(wait: nil, **attrs)
      @run.update!(attrs.merge(state: { "pc" => @pc, "vars" => @ctx.vars, "counters" => @counters, "seq" => @seq, "wait" => wait }.compact))
    end

    def close_wait(result)
      step = @run.steps.reverse.find { |s| s["result"] == "waiting" }
      step["result"] = result if step
    end
  end
end
