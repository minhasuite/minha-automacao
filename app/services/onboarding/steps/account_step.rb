module Onboarding
  module Steps
    # Instalação nova, sem ninguém: cria a conta do dono (e a instalação).
    class AccountStep < Step
      describe key: "account", icon: "user-circle", art: "welcome"

      # Quem já entrou com a conta pronta (criar conta, convite) não vê este passo.
      def self.skip?(ctx) = ctx.user.present? && !Onboarding.done?(ctx, key)
      def self.ready?(ctx) = ctx.user.nil? && Onboarding.fresh_install?
      def self.needs_site? = false
      def self.optional? = false

      def self.save(ctx, params)
        return I18n.t("onboarding.account.taken") unless Onboarding.fresh_install?

        name = params[:name].to_s.squish
        User.transaction do
          tenant = Tenant.create!(name: I18n.t("onboarding.account.tenant_name", name: name.split.first || "-"))
          ctx.user = User.create!(tenant: tenant, role: "owner", name: name, email: params[:email], password: params[:password].to_s)
        end
        nil
      rescue ActiveRecord::RecordInvalid => e
        e.record.errors.full_messages.to_sentence
      end
    end
  end
end
