module Web
  # Assist do local (ondaB1; o "Assistentes de voz" do HA): pipelines (idioma,
  # agente, STT/TTS/palavra de ativação por motor), depuração (cada execução
  # com as etapas e o tempo), frases (catálogo das intenções no idioma e
  # teste ao vivo, sem executar) e, nas abas dos próximos pacotes, satélites
  # e servidor MCP. Ver e mudar: técnico ou dono do local.
  class AssistSettingsController < ApplicationController
    TABS = %w[pipelines satelites depuracao frases mcp].freeze

    before_action -> { @site = Site.find(params[:site_id]) }
    before_action -> { authorize_site!(@site, :manage) }

    def show
      @tab = params[:aba].presence_in(self.class::TABS) || "pipelines"
      @pipelines = AssistPipeline.where(site: @site).order(preferred: :desc, created_at: :asc).to_a
      case @tab
      when "depuracao" then @runs = AssistRun.where(site: @site).includes(:user, :pipeline).order(created_at: :desc).limit(50)
      when "frases" then frases
      when "mcp" then @mcp_tokens = mcp_tokens
      when "satelites" then @satellites = AssistSatellite.where(site: @site).includes(:area, :pipeline, :device).order(:name).to_a
      end
    end

    def create_pipeline
      p = AssistPipeline.new(site: @site)
      save_pipeline(p, t("assist_settings.flash.created"))
    end

    def update_pipeline = save_pipeline(AssistPipeline.where(site: @site).find(params[:id]), t("assist_settings.flash.saved"))

    def destroy_pipeline
      AssistPipeline.where(site: @site).find(params[:id]).destroy!
      redirect_to site_assist_settings_path(@site), notice: t("assist_settings.flash.removed")
    end

    def create_satellite = save_satellite(AssistSatellite.new(site: @site), t("assist_settings.flash.sat_created"))
    def update_satellite = save_satellite(AssistSatellite.where(site: @site).find(params[:id]), t("assist_settings.flash.sat_saved"))

    def destroy_satellite
      AssistSatellite.where(site: @site).find(params[:id]).destroy!
      redirect_to site_assist_settings_path(@site, aba: "satelites"), notice: t("assist_settings.flash.sat_removed")
    end

    # Pergunta ao satélite Wyoming o que ele é ("describe"); ESPHome: o aparelho integrado.
    def test_satellite
      sat = AssistSatellite.where(site: @site).find(params[:id])
      back = site_assist_settings_path(@site, aba: "satelites")
      return redirect_to(back, notice: t("assist_settings.flash.sat_device", name: sat.device&.name)) unless sat.kind == "wyoming"

      info = Wyoming.describe(sat.host, sat.port.presence || Wyoming::PORTS[:satellite])
      sat.seen!
      redirect_to back, notice: t("assist_settings.flash.sat_ok", name: info.dig("satellite", "name").presence || sat.name)
    rescue Wyoming::Error => e
      sat.update_columns(last_error: e.message.truncate(200))
      redirect_to back, alert: e.message
    end

    # Token MCP novo: aparece uma vez na própria página (sem Turbo, sem flash).
    def create_mcp_token
      _token, @new_token = ApiToken.mcp!(current_user, @site, params[:name])
      @tab = "mcp"
      @pipelines = []
      @mcp_tokens = mcp_tokens
      render :show
    end

    def revoke_mcp_token
      mcp_tokens.find { |tk| tk.id == params[:id] }&.revoke!
      redirect_to site_assist_settings_path(@site, aba: "mcp"), notice: t("assist_settings.flash.mcp_revoked")
    end

    private

    def mcp_tokens = ApiToken.active.mcp.where(site_id: @site.id, user_id: current_user.id).where("access_expires_at > ?", Time.current).order(:created_at).to_a

    def save_satellite(sat, notice)
      f = params.require(:satellite).permit(:name, :kind, :host, :port, :device_id, :area_id, :pipeline_id, :enabled)
      sat.assign_attributes(f.to_h.transform_values(&:presence).merge("enabled" => f[:enabled] != "0"))
      # Papel da voz do satélite: só os da lista (no máximo morador).
      role = params.dig(:satellite, :role).to_s.presence_in(AssistSatellite::ROLES)
      sat.role = role if role
      back = site_assist_settings_path(@site, aba: "satelites")
      return redirect_to(back, notice: notice) if sat.save

      redirect_to back, alert: sat.errors.full_messages.to_sentence
    end

    # Teste de frase (GET, não executa nada): qual intenção e quais slots; e
    # uma frase-modelo contra um exemplo.
    def frases
      @language = Assist.language(params[:idioma].presence || @site.language.presence)
      if (text = params[:texto].to_s.squish).present?
        @heard = text
        @understood = Assist.understand(@site, text, language: @language)
      end
      return if params[:modelo].blank?

      @template = params[:modelo].to_s.first(300)
      @sample = params[:exemplo].to_s.first(300)
      @template_error = Assist::Sentences.error(@template)
      @template_match = Assist::Sentences.match(@template, Assist.normalize(@sample)) unless @template_error
    end

    def save_pipeline(pipeline, notice)
      f = params.require(:pipeline).permit(:name, :language, :agent, :llm_provider, :preferred)
      pipeline.assign_attributes(f.to_h)
      %w[stt tts wake].each { |kind| pipeline[kind] = engine_cfg(kind) }
      return redirect_to(site_assist_settings_path(@site), notice: notice) if pipeline.save

      redirect_to site_assist_settings_path(@site), alert: pipeline.errors.full_messages.to_sentence
    end

    # {engine:, campos do motor} a partir de pipeline[<kind>_engine] e pipeline[<kind>][<motor>][campo].
    def engine_cfg(kind)
      key = params.dig(:pipeline, "#{kind}_engine").to_s
      plugin = Assist::Engines[key] or return {}

      raw = params.dig(:pipeline, kind, key)
      values = raw.respond_to?(:permit) ? raw.permit(*plugin.fields.filter_map { |name, _type, only| name if only.nil? || only.include?(kind.to_sym) }).to_h : {}
      { "engine" => key }.merge(values.transform_values { |v| v.to_s.strip }.compact_blank)
    end
  end
end
