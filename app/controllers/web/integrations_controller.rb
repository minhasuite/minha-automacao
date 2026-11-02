module Web
  # Integrações do local (F8c), como no HA: em cima as que já existem (card
  # com resumo, sem lista de aparelhos), embaixo o catálogo pesquisável. Todo
  # passo por tipo é do plugin (`Integrations::Plugin`): aqui só se segue o
  # `Outcome`. Ver: qualquer papel; o resto: técnico ou dono.
  class IntegrationsController < ApplicationController
    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      @integrations = @site.integrations.order(:name).to_a
      ids = @integrations.map(&:id)
      @device_counts = Device.where(integration_id: ids).group(:integration_id).count
      @point_counts = Point.joins(:device).where(devices: { integration_id: ids }).group("devices.integration_id").count
      @pending = @integrations.to_h { |i| [ i.id, Integrations.pending(i).size ] }
      q = params[:q].to_s.squish.downcase
      @catalog = Integrations.plugins.select { |p| q.empty? || "#{p.title} #{p.description}".downcase.include?(q) }
    end

    def new
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @plugin = Integrations.plugin(params[:tipo]) or return redirect_to(site_integrations_path(@site, anchor: "adicionar"))
      @found = discover if params[:procurar].present? && @plugin.discovers?
    end

    def create
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @plugin = Integrations.plugin(params[:tipo]) or return redirect_to(site_integrations_path(@site))

      follow(@plugin.setup(@site, form))
    end

    # Passo de login / Reconfigurar (QR, captcha, senha).
    def connect
      load_for(:manage)
      @locals = @plugin.connect_locals(@integration, params.merge(redirect_uri: integrations_oauth_callback_url))
    rescue Integrations::Error => e
      @locals = {}
      flash.now[:alert] = e.message
    end

    def login
      load_for(:manage)
      follow(@plugin.login(@integration, form))
    end

    # Volta do login externo (OAuth): o `state` assinado diz a integração (ou o Drive do backup).
    def oauth_callback
      id = Integrations.from_oauth_state(params[:state]) or return redirect_to(root_path, alert: t("integrations.flash.login_expired"))
      return backup_drive_callback(id) if id.to_s.start_with?("backup_drive:")

      params[:id] = id
      load_for(:manage)
      return follow(@plugin.outcome(:connect, integration: @integration, alert: t("integrations.flash.login_cancelled"))) if params[:error].present?

      follow(@plugin.oauth_callback(@integration, { code: params[:code], redirect_uri: integrations_oauth_callback_url }))
    end

    # Consultado pela tela a cada 3 s: {url} quando é hora de ir para os encontrados.
    def status
      load_for(:manage)
      done = if @integration.status == "syncing" then false
      elsif params[:sync].present? then true
      else @plugin.logged_in?(@integration)
      end
      render json: done ? { url: found_integration_path(@integration) } : {}
    rescue Integrations::Error => e
      render json: { error: e.message }
    end

    def found
      load_for(:view)
      @entries = @integration.found
      @known = Integrations.matched_ids(@integration)
      @areas = @site.areas.order(:name).to_a
    end

    # ondaA2 A12: JSON saneado para anexar num pedido de ajuda.
    def diagnostics
      load_for(:manage)
      json = JSON.pretty_generate((@plugin || Integrations::Plugin).diagnostics(@integration))
      send_data json, type: "application/json", filename: "diagnostico-#{@integration.driver}-#{Time.current.strftime('%Y%m%d-%H%M')}.json"
    end

    def adopt
      load_for(:manage)
      areas = params.fetch(:area, {}).to_unsafe_h
      ids = params[:all].present? ? Integrations.pending(@integration).map { |e| e["id"] } : Array(params[:pick])
      count = Integrations.adopt!(@integration, ids.to_h { |id| [ id, areas[id] ] })
      redirect_to site_devices_path(@site, integracao: @integration.id), notice: t("integrations.flash.adopted", n: count)
    end

    def sync
      load_for(:manage)
      Integrations.start_sync!(@integration)
      redirect_to found_integration_path(@integration), notice: t("integrations.flash.syncing")
    end

    # Intervalo da varredura da conta (minutos; vazio ou 0 = só manual).
    def update
      load_for(:manage)
      ok = @integration.update(params.require(:integration).permit(:poll_min))
      redirect_to site_integrations_path(@site), **(ok ? { notice: t("integrations.flash.interval_saved") } : { alert: @integration.errors.full_messages.to_sentence })
    end

    def destroy
      load_for(:manage)
      @integration.destroy!
      redirect_to site_integrations_path(@site), notice: t("integrations.flash.removed")
    end

    private

    def load_for(action)
      @integration = Integration.find(params[:id])
      @site = @integration.site
      @plugin = @integration.plugin
      authorize_site!(@site, action)
    end

    def form = params.fetch(:integration, {})

    # Google Drive do backup (Configurações → Saúde): só quem pediu e pode ligar.
    def backup_drive_callback(state)
      drive = Backups::Destinations::GoogleDrive
      raise ActiveRecord::RecordNotFound unless state == drive.state_for(current_user) && drive.manageable_by?(current_user)
      return redirect_to(settings_health_path, alert: t("integrations.flash.drive_cancelled")) if params[:error].present?

      drive.connect!(params[:code], integrations_oauth_callback_url)
      redirect_to settings_health_path, notice: t("integrations.flash.drive_connected")
    rescue Integrations::Error, Backups::Error, SafeHttp::Error => e
      redirect_to settings_health_path, alert: t("integrations.flash.drive_error", error: e.message)
    end

    # Pacote 1: só lista o que se anuncia na rede (mDNS); nada é cadastrado.
    def discover
      @plugin.discover
    rescue SystemCallError, IOError, SocketError => e
      Rails.logger.warn("[mdns] #{@plugin.key}: #{e.message}")
      []
    end

    def follow(o)
      flash_now = { notice: o.notice, alert: o.alert }.compact
      if o.to == :form
        flash_now.each { |k, v| flash.now[k] = v }
        return render(:new, status: :unprocessable_content)
      end

      url = { found: -> { found_integration_path(o.integration) }, connect: -> { connect_integration_path(o.integration, **o.params) },
              devices: -> { site_devices_path(@site) } }.fetch(o.to, -> { site_integrations_path(@site) }).call
      redirect_to url, **flash_now
    end
  end
end
