module Api
  module V1
    # tuya: pareamento de aparelhos pelo app. O provedor é um plugin de
    # integração (`Integrations.plugin(:provider)`) com `pairing_session` e
    # `pair`; nada aqui sabe de Tuya. Técnico ou dono; chave de integração não.
    class PairingsController < BaseController
      around_action :with_user_locale

      # `session` é do controlador (cookies): a ação se chama `account`.
      def account
        site, plugin = site_and_plugin
        info = plugin.pairing_session(site, current_user) or
          return render_error(:unsupported, I18n.t("integrations.pairing.unsupported"), status: :unprocessable_content)

        render_data(info)
      end

      def create
        site, plugin = site_and_plugin
        device = plugin.pair(site, params.except(:controller, :action, :site_id, :provider).permit!.to_h.with_indifferent_access)
        render_data(DeviceSerializer.new(device, params: { reveal: true }).to_h, status: device.previously_new_record? ? :created : :ok)
      rescue Integrations::Error => e
        render_error(:pairing_failed, e.message, status: :unprocessable_content)
      end

      private

      def site_and_plugin
        site = Site.find(params[:site_id])
        authorize_site!(site, :manage)
        plugin = Integrations.plugin(params[:provider]) or raise ActiveRecord::RecordNotFound
        [ site, plugin ]
      end

      def with_user_locale(&)
        I18n.with_locale(Localized.valid(current_user.dashboard_prefs.to_h["locale"]) || Localized.from_header(request.headers["Accept-Language"]) || I18n.default_locale, &)
      end
    end
  end
end
