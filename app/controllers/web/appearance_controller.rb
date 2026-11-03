module Web
  # Configurações → Aparência (ondaB2 B11): o tema de cada pessoa (no perfil
  # ou só neste aparelho, por cima do tema do painel), os temas criados pela
  # casa (cores, papel de parede, vidro e fonte, com prévia) e a barra
  # lateral de cada pessoa (ordem e o que aparece).
  class AppearanceController < ApplicationController
    before_action :require_admin!, only: %i[create_theme update_theme destroy_theme]

    def show
      @themes = Dashboards::Themes.all
      @custom = DashboardTheme.order(:name).to_a
      @editing = @custom.find { |t| t.id == params[:tema] }
      @entries = helpers.sidebar_entries(all: true)
    end

    def update
      prefs = current_user.dashboard_prefs.to_h
      case params[:op]
      when "my_theme" then prefs["theme"] = theme_key(params[:key])
      when "device_theme" then device_theme(theme_key(params[:key]))
      when "sidebar" then prefs["sidebar"] = sidebar(prefs["sidebar"].to_h)
      when "sidebar_reset" then prefs.delete("sidebar")
      end
      current_user.update!(dashboard_prefs: prefs.compact)
      redirect_to settings_appearance_path(anchor: params[:op].to_s.start_with?("sidebar") ? "barra" : "tema"), notice: t("appearance.saved")
    end

    def create_theme
      theme = DashboardTheme.create!(theme_params)
      redirect_to settings_appearance_path(anchor: "temas"), notice: t("appearance.created", name: theme.name)
    end

    def update_theme
      DashboardTheme.find(params[:id]).update!(theme_params)
      redirect_to settings_appearance_path(anchor: "temas"), notice: t("appearance.saved")
    end

    def destroy_theme
      DashboardTheme.find(params[:id]).destroy!
      redirect_to settings_appearance_path(anchor: "temas"), notice: t("appearance.removed")
    end

    private

    def require_admin!
      back_with_alert(t("appearance.admin_only")) unless current_user.admin?
    end

    # Só chave que existe (pronta ou da casa); vazio = segue o painel.
    def theme_key(key) = key.presence && Dashboards::Themes[key] ? key : nil

    def device_theme(key)
      return cookies.delete(:ma_theme) unless key

      cookies[:ma_theme] = { value: key, expires: 1.year, httponly: true, same_site: :lax }
    end

    # Barra lateral: mover um item (↑/↓) ou mostrar/esconder; a ordem guardada é a lista toda.
    def sidebar(current)
      keys = helpers.sidebar_entries(all: true).map { |e| e[:key] }
      order = (Array(current["order"]) & keys) | keys
      hidden = Array(current["hidden"]) & keys
      item = params[:item].to_s
      if (i = order.index(item))
        case params[:dir]
        when "up" then order.insert([ i - 1, 0 ].max, order.delete_at(i))
        when "down" then order.insert([ i + 1, order.size - 1 ].min, order.delete_at(i))
        when "toggle" then hidden.include?(item) ? hidden.delete(item) : hidden << item
        end
      end
      { "order" => order, "hidden" => hidden - ApplicationHelper::SIDEBAR_FIXED }
    end

    def theme_params
      params.require(:theme).permit(:name, :accent, :accent2, :wall_style, :glass, :font)
    end
  end
end
