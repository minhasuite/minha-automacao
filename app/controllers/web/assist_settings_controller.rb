module Web
  # Assist do local (ondaB1; o "Assistentes de voz" do HA): pipelines (idioma,
  # agente, STT/TTS/palavra de ativação por motor), depuração (cada execução
  # com as etapas e o tempo), frases (catálogo das intenções no idioma e
  # teste ao vivo, sem executar) e, nas abas dos próximos pacotes, satélites
  # e servidor MCP. Ver e mudar: técnico ou dono do local.
  class AssistSettingsController < ApplicationController
    TABS = %w[pipelines depuracao frases].freeze

    before_action -> { @site = Site.find(params[:site_id]) }
    before_action -> { authorize_site!(@site, :manage) }

    def show
      @tab = params[:aba].presence_in(self.class::TABS) || "pipelines"
      @pipelines = AssistPipeline.where(site: @site).order(preferred: :desc, created_at: :asc).to_a
      case @tab
      when "depuracao" then @runs = AssistRun.where(site: @site).includes(:user, :pipeline).order(created_at: :desc).limit(50)
      when "frases" then frases
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

    private

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
      values = raw.respond_to?(:permit) ? raw.permit(*plugin.fields.map(&:first)).to_h : {}
      { "engine" => key }.merge(values.transform_values { |v| v.to_s.strip }.compact_blank)
    end
  end
end
