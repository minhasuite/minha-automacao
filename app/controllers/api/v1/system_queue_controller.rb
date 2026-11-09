module Api
  module V1
    # Fila e jobs (docs/fila.md) para o app: resumo do Solid Queue, latência
    # dos comandos (fila x aparelho, por driver), processos, recorrentes e
    # estatística por classe de job. Só o dono, numa instalação só (mesma
    # regra da tela Configurações → Fila); chave de integração não entra.
    class SystemQueueController < BaseController
      # GET /api/v1/system/queue
      def show
        unless QueueMonitor.visible_to?(current_user)
          return render_error(:forbidden, "Só o dono do servidor pode ver a fila.", status: :forbidden)
        end

        now = Time.current
        render_data(QueueMonitor.snapshot(now), meta: { generated_at: now, windows: QueueMonitor::WINDOWS.keys, unit: "s" })
      end
    end
  end
end
