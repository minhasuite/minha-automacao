module Web
  # Mídia do local (ondaC2, C8/C9; o painel Mídia do HA): players com o que
  # está tocando e controles, grupos, "Falar" (TTS em qualquer player) e o
  # navegador das fontes (MediaSources::PLUGINS) com "Tocar em…". Navegar é
  # para qualquer papel; tocar e controlar pedem comando no risco do player;
  # enviar e apagar arquivos pedem gerenciar. No app, a mesma tela pelas
  # telas do servidor (appweb).
  class MediaController < ApplicationController
    before_action -> { @site = Site.find(params[:site_id]) }
    before_action -> { authorize_site!(@site, :view) }, only: %i[index browse]

    def index
      @sources = MediaSources.available(@site)
      @players = MediaSources.players(@site)
    end

    def browse
      @source = MediaSources.for(params[:source]) or raise ActiveRecord::RecordNotFound
      @path = params[:path].to_s
      @query = params[:q].to_s.strip.first(100).presence
      @page = @source.browse(@site, @path, query: @query)
      @item = @page.items.find { |i| i.id.to_s == params[:item].to_s && !i.folder? } if params[:item].present?
      @players = players_for(@source, @item) if @item
      @preview = preview(@item)
    rescue ArgumentError, Integrations::Error => e
      @error = e.message
      @page ||= MediaSources::Page.new(title: @source.title, parent: nil, items: [])
    end

    def play
      source = MediaSources.for(params[:source]) or raise ActiveRecord::RecordNotFound
      point = players_for(source, params[:item]).find { |p| p.id == params[:player_id] } or raise ActiveRecord::RecordNotFound
      command(point, "play_media") { source.media_url(@site, params[:item]) }
      redirect_to site_media_browse_path(@site, source.key, path: params[:path], item: params[:item]), **flash_for(point)
    end

    def speak
      point = MediaSources.players(@site).find { |p| p.id == params[:player_id] } or raise ActiveRecord::RecordNotFound
      text = params[:text].to_s.squish.first(Points::Command::MAX_SPEECH)
      command(point, "play_media") { text.present? ? MediaSources.speech_url(@site, text) : raise(ArgumentError, t("media.index.say_empty")) }
      redirect_to site_media_path(@site), **flash_for(point)
    end

    # Controles do card do player (tocar/pausar, volume, grupo).
    def control
      point = MediaSources.players(@site).find { |p| p.id == params[:id] } or raise ActiveRecord::RecordNotFound
      command(point, params[:command].to_s) { params[:value] }
      redirect_to site_media_path(@site, anchor: "player-#{point.id}"), alert: @error
    end

    def mkdir = files { MediaSources::Local.mkdir(@site, params[:path], params[:name]) }
    def destroy = files(back: File.dirname(params[:path].to_s).delete_prefix(".")) { MediaSources::Local.delete(@site, params[:path]) }

    def upload
      files { Array(params[:files]).compact_blank.first(20).each { |f| MediaSources::Local.upload(@site, params[:path], f) } }
    end

    private

    def viewer_allowed? = true

    def preview(item)
      item && @source.preview_url(@site, item.id)
    rescue ArgumentError, Integrations::Error
      nil
    end

    # Players que tocam o item (a biblioteca de um player só toca nele).
    def players_for(source, item)
      ids = source.player_ids(@site, item.respond_to?(:id) ? item.id : item)
      MediaSources.players(@site).select { |p| ids.nil? || ids.include?(p.id) }
    end

    def command(point, name)
      authorize_site!(@site, :command, risk: point.risk)
      @error = Points::Command.call(point, name, yield, source: "web", user: current_user).error
    rescue Points::Command::Error, ArgumentError, Integrations::Error, Ai::Client::Error => e
      @error = e.message
    end

    def flash_for(point) = @error ? { alert: @error } : { notice: t("media.sent", name: Notifier::Channels::Player.name(point)) }

    def files(back: params[:path])
      authorize_site!(@site, :manage)
      yield
      redirect_to site_media_browse_path(@site, "local", path: back.presence), notice: t("media.files.done")
    rescue ArgumentError, SystemCallError => e
      redirect_to site_media_browse_path(@site, "local", path: back.presence), alert: e.message
    end
  end
end
