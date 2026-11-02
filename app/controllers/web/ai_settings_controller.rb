module Web
  # Configurações → IA (Lote 2): um cartão por provedor do registro
  # (Ai::PROVIDERS) com a chave cifrada, URL (Ollama), modelo e "Testar
  # conexão"; o provedor padrão e o limite mensal com o contador; e o uso
  # (cada chamada com modelo, tokens, custo e origem). Ver: administradores;
  # mudar: o Dono. A chave nunca volta para a tela.
  class AiSettingsController < ApplicationController
    before_action :require_admin_web!
    before_action :require_owner!, except: :show

    def show
      @accounts = AiAccount.all.index_by(&:provider)
      @budget = Ai::Budget.for(current_user.tenant)
      @calls = AiCall.includes(:automation, :site).order(created_at: :desc).limit(50)
      @by_source = AiCall.this_month.charged.group(:source).sum(:cost)
    end

    def update
      Ai::Budget.save!(current_user.tenant, params.fetch(:ai, {}).permit(:default_provider, :limit_usd, :limit_calls))
      redirect_to settings_ai_path, notice: t("ai_settings.flash.limits")
    end

    def provider
      plugin = Ai.provider(params[:provider]) or return redirect_to(settings_ai_path, alert: t("ai_settings.flash.unknown"))
      account = AiAccount.find_or_initialize_by(provider: plugin.key)
      p = params.fetch(:account, {}).permit(:api_key, :base_url, :model, :enabled, :remove_key)
      account.api_key = p[:api_key].strip if p[:api_key].present? # vazio = mantém a guardada
      account.api_key = nil if p[:remove_key] == "1"
      account.base_url = p[:base_url] if plugin.custom_url?
      account.model = p[:model]
      account.enabled = p[:enabled] != "0"
      return redirect_to(settings_ai_path(anchor: plugin.key), alert: account.errors.full_messages.to_sentence) unless account.save

      redirect_to settings_ai_path(anchor: plugin.key), notice: t("ai_settings.flash.saved", name: plugin.label)
    end

    # Pergunta curta ao provedor; conta como chamada (origem "teste").
    def check
      account = AiAccount.find_by(provider: params[:provider].to_s)
      return redirect_to(settings_ai_path, alert: t("ai_settings.flash.save_first")) unless account&.usable?

      notice = if account.plugin.supports?(:text)
        res = Ai::Request.call(tenant: current_user.tenant, provider: account.provider, source: "teste", max_tokens: 30, timeout: 30,
                               prompt: "Responda apenas com a palavra OK.")
        t("ai_settings.flash.answered", name: account.plugin.label, model: res.model, tokens: res.tokens)
      else # só voz (Lote 5): gera uma fala curta
        res = Ai::Audio.speak(tenant: current_user.tenant, provider: account.provider, source: "teste", text: "OK")
        t("ai_settings.flash.spoke", name: account.plugin.label, model: res.model, bytes: res.data[:data].bytesize)
      end
      account.update!(last_ok_at: Time.current, last_error: nil)
      redirect_to settings_ai_path(anchor: account.provider), notice: notice
    rescue Ai::Client::Error => e
      account.update!(last_error: e.message.truncate(200))
      redirect_to settings_ai_path(anchor: account.provider), alert: "#{account.plugin.label}: #{e.message}"
    end

    private

    def require_admin_web!
      redirect_to settings_path, alert: t("ai_settings.flash.admins") unless current_user.admin?
    end
  end
end
