module Web
  # Troca de idioma (produto): guarda no cookie e, com sessão, na pessoa.
  class LocalesController < ApplicationController
    skip_before_action :require_login!

    def update
      locale = Localized.valid(params[:locale]) or return redirect_back(fallback_location: root_path)

      cookies.permanent[Localized::COOKIE] = { value: locale, same_site: :lax }
      current_user&.update!(dashboard_prefs: current_user.dashboard_prefs.merge("locale" => locale))
      redirect_back fallback_location: root_path, notice: I18n.t("flash.locale_saved", locale: locale) # no idioma novo
    end
  end
end
