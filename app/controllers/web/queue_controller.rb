module Web
  # Configurações → Fila (docs/fila.md): o Solid Queue e a latência dos
  # comandos (fila x aparelho), com tentar de novo / descartar job com erro.
  # Só o dono, numa instalação só (a fila é do servidor inteiro), como os Logs.
  # A tela se recarrega sozinha a cada 10 s (ss-reload com morph).
  class QueueController < ApplicationController
    before_action :require_visible!

    def show
      @now = Time.current
      @summary = QueueMonitor.summary(@now)
      @latency = QueueMonitor.command_latency(@now)
      @recent = QueueMonitor.recent_commands
      @failed_commands = QueueMonitor.failed_commands(@now)
      @jobs = QueueMonitor.job_stats(@now)
      @processes = QueueMonitor.processes(@now)
      @recurring = QueueMonitor.recurring
      @tab = QueueMonitor::TABS.include?(params[:aba]) ? params[:aba] : (@summary[:failed].positive? ? "erros" : "execucao")
      @rows = QueueMonitor.list(@tab, @now)
    end

    def retry_job
      QueueMonitor.retry!(params[:id])
      redirect_to settings_queue_path(aba: "erros"), notice: t("queue.retried")
    end

    def discard_job
      QueueMonitor.discard!(params[:id])
      redirect_to settings_queue_path(aba: "erros"), notice: t("queue.discarded")
    end

    private

    def require_visible!
      raise ActiveRecord::RecordNotFound unless QueueMonitor.visible_to?(current_user)
    end
  end
end
