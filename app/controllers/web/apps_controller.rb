module Web
  # Configurações → Aplicativos (F8g, só o dono): instalados, loja (catálogo
  # de config/apps/*.yml) e a página do app (Informações, Configuração, Log).
  # Tudo passa pelo supervisor (Apps::Supervisor); toda ação vira AuditEvent.
  class AppsController < ApplicationController
    TABS = %w[info config log].freeze

    before_action :require_owner!
    before_action :load_app, except: %i[index store]
    rescue_from Apps::Supervisor::Error do |e|
      redirect_to(@app ? app_path(@app.key) : apps_path, alert: e.message)
    end

    def index
      @statuses, @offline = fetch_statuses
      @installed = AppCatalog.all.select { |m| @statuses.dig(m.key, "installed") }
    end

    def store
      @apps = AppCatalog.search(params[:q], params[:categoria])
      @statuses, @offline = fetch_statuses
    end

    def show
      @tab = params[:aba].presence_in(TABS) || "info"
      @status = Apps::Supervisor.status(@app.key) if Apps::Supervisor.configured?
    rescue Apps::Supervisor::Error => e
      @offline = e.message
    end

    def install
      Apps::Supervisor.install(@app.key, options: option_params, boot: params[:boot] == "1", watchdog: params[:watchdog] == "1")
      done("install", t("apps.flash.installing", name: @app.name))
    end

    def update
      body = params.key?(:options) ? { options: option_params } : { boot: params[:boot] == "1", watchdog: params[:watchdog] == "1" }
      Apps::Supervisor.configure(@app.key, **body)
      done("configure", t("apps.flash.configured", name: @app.name), tab: (body.key?(:options) ? "config" : nil), details: body.except(:options))
    end

    def act
      action = params[:do].presence_in(%w[start stop restart]) or return redirect_to(app_path(@app.key))
      Apps::Supervisor.act(@app.key, action)
      done(action, t("apps.flash.#{action}", name: @app.name))
    end

    def upgrade
      Apps::Supervisor.upgrade(@app.key)
      done("upgrade", t("apps.flash.upgrading", name: @app.name, version: @app.version), details: { version: @app.version })
    end

    def destroy
      keep = params[:keep_data] == "1"
      Apps::Supervisor.uninstall(@app.key, keep_data: keep)
      audit!("uninstall", keep_data: keep)
      redirect_to apps_path, notice: t(keep ? "apps.flash.uninstalled_kept" : "apps.flash.uninstalled", name: @app.name)
    end

    def logs
      @lines = Apps::Supervisor.logs(@app.key, params.fetch(:linhas, 200))
      render layout: false
    rescue Apps::Supervisor::Error => e
      @lines = e.message
      render layout: false
    end

    # Interface web: o app publica a própria porta na rede de casa (o proxy
    # pelo Rails não leva websocket); aqui só a checagem de papel e o desvio.
    def launch
      port = @app.web_ui&.dig("port") or return redirect_to(app_path(@app.key))
      audit!("open")
      host = request.host.match?(/\A[\d.]+\z/) ? request.host : ENV.fetch("APP_HOST", request.host)
      redirect_to "http://#{host}:#{port.to_i}#{@app.web_ui['path']}", allow_other_host: true
    end

    private

    def load_app
      @app = AppCatalog.find(params[:key]) or render("web/shared/not_found", status: :not_found)
    end

    def fetch_statuses
      return [ {}, t("apps.local_hint") ] unless Apps::Supervisor.configured?

      [ Apps::Supervisor.statuses, nil ]
    rescue Apps::Supervisor::Error => e
      [ {}, e.message ]
    end

    def option_params
      keys = @app.options.map { |o| o["key"] }
      params.fetch(:options, ActionController::Parameters.new).permit(*keys).to_h
    end

    def done(action, notice, tab: nil, details: {})
      audit!(action, details)
      redirect_to app_path(@app.key, aba: tab), notice: notice
    end

    def audit!(action, details = {})
      AuditEvent.create!(tenant_id: current_user.tenant_id, user_id: current_user.id, action: "app.#{action}",
                         auditable_type: "App", details: details.merge(key: @app.key))
      Rails.logger.info("[apps] #{current_user.email} #{action} #{@app.key}")
    end
  end
end
