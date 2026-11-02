module Web
  # Configurações → Logs (ondaA2 A12): o resumo de avisos e erros do servidor
  # (SystemLog) com filtro por nível, fonte (integração) e texto, e o log
  # completo dos serviços pelo supervisor; os dois para baixar. Só o dono, e
  # só num servidor de uma instalação (o log é do servidor inteiro).
  class LogsController < ApplicationController
    SERVICES = %w[web worker supervisor].freeze
    before_action :require_visible!

    def show
      @tab = params[:aba] == "completo" ? "completo" : "resumo"
      if @tab == "resumo"
        @logs = filtered.limit(300)
        @sources = SystemLog.distinct.order(:source).pluck(:source)
      else
        @service = SERVICES.include?(params[:servico]) ? params[:servico] : "web"
        @raw, @error = raw_lines
      end
      respond_to do |f|
        f.html
        f.text { send_data(@tab == "resumo" ? SystemLog.to_text(filtered) : @raw.to_s, type: "text/plain", filename: "log-#{@tab}-#{Time.current.strftime('%Y%m%d-%H%M')}.txt") }
      end
    end

    def destroy
      SystemLog.delete_all
      redirect_to settings_logs_path, notice: t("logs.cleared")
    end

    private

    def require_visible!
      raise ActiveRecord::RecordNotFound unless SystemLog.visible_to?(current_user)
    end

    def filtered
      scope = SystemLog.recent
      scope = scope.where(level: params[:nivel] == "error" ? %w[error fatal] : params[:nivel]) if SystemLog::LEVELS.include?(params[:nivel])
      scope = scope.where(source: params[:fonte]) if params[:fonte].present?
      scope = scope.where("message ILIKE ?", "%#{SystemLog.sanitize_sql_like(params[:q].to_s.squish)}%") if params[:q].present?
      scope
    end

    def raw_lines
      return [ nil, t("logs.no_supervisor") ] unless Apps::Supervisor.configured?

      text = Apps::Supervisor.request(:get, "/system/logs?service=#{@service}&lines=#{params.fetch(:linhas, 500).to_i.clamp(10, 5000)}").dig("data", "lines").to_s
      text = text.lines.grep(/#{Regexp.escape(params[:q].to_s)}/i).join if params[:q].present?
      [ text, nil ]
    rescue Apps::Supervisor::Error => e
      [ nil, e.message ]
    end
  end
end
