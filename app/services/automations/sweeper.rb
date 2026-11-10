module Automations
  # Execuções sem dono (docs/confiabilidade.md). Reinício do worker (deploy)
  # mata a thread que rodava a execução e ninguém a fechava: ficava "rodando"
  # para sempre e a fila (modo `queued`) atrás dela não andava.
  #
  # `sweep!(stale_before:)` (AutomationSweepJob: no início do worker com o
  # instante do início, e a cada 5 min com `Reliability.run_max` = 15 min):
  #   - "rodando" sem atualizar desde `stale_before` → `interrupted` (passo no
  #     trace, `after_run`: a próxima da fila começa, o ramo do "Em paralelo"
  #     avisa o pai);
  #   - "esperando" com `resume_at` vencido (o AutomationResumeJob se perdeu):
  #     retoma se o atraso é pequeno (< `run_max`); atraso maior fecha como
  #     `interrupted` em vez de agir fora de hora (como a agenda atrasada > 5 min);
  #   - automação com execução "na fila" e nenhuma ativa: começa a próxima.
  module Sweeper
    # Espera vencida há menos que isso é do próprio job atrasado (fila cheia): não mexe.
    RESUME_GRACE = 2.minutes

    module_function

    def sweep!(stale_before: nil, now: Time.current)
      out = { interrupted: 0, resumed: 0, started: 0 }
      Tenant.find_each do |tenant|
        ActsAsTenant.with_tenant(tenant) do
          limit = stale_before || now - Reliability.run_max(tenant)
          AutomationRun.where(status: "running", updated_at: ...limit).find_each do |run|
            out[:interrupted] += 1 if interrupt!(run, "Interrompida: a execução parou sem terminar (reinício do sistema?)", now: now)
          end
          late = now - Reliability.run_max(tenant)
          AutomationRun.real.where(status: "waiting", resume_at: ...(now - RESUME_GRACE)).find_each do |run|
            if run.resume_at < late
              out[:interrupted] += 1 if interrupt!(run, "Interrompida: a espera venceu há #{Reliability.duration_text(now - run.resume_at)} e não foi retomada fora de hora", now: now)
            else
              AutomationResumeJob.perform_later(run.id, run.state["seq"])
              out[:resumed] += 1
            end
          end
          out[:started] += start_queued!
        end
      end
      out
    end

    # Fecha a execução (só se ainda estiver aberta no banco) e segue a corrente.
    def interrupt!(run, reason, now: Time.current)
      step = { "at" => now.iso8601(3), "kind" => "interrupted", "title" => reason, "result" => "error" }
      closed = AutomationRun.where(id: run.id, status: run.status, finished_at: nil)
                            .update_all([ "status = 'interrupted', finished_at = ?, resume_at = NULL, error = ?, updated_at = ?, steps = steps || ?::jsonb", # rubocop:disable Rails/SkipsModelValidations
                                          now, reason.truncate(255), now, [ step ].to_json ]) == 1
      return false unless closed

      run.reload
      return true if run.dry_run

      if (parent = run.state["parent_id"])
        Triggers.event(run.site_id, "parallel_branch_finished", { "parent_id" => parent, "run_id" => run.id, "status" => "interrupted" })
      else
        run.automation.after_run(run)
      end
      true
    rescue StandardError => e
      Rails.error.report(e, handled: true)
      true
    end

    def start_queued!
      ids = AutomationRun.real.where(status: "queued").distinct.pluck(:automation_id)
      Automation.where(id: ids).count { |a| a.start_queued! }
    end
  end
end
