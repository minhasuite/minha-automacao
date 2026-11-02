module Onboarding
  module Steps
    # Convidar a família (link de uso único, como em Pessoas, com QR) e
    # instalar o app: o QR abre esta instalação no celular (PWA / app).
    class FamilyStep < Step
      describe key: "family", icon: "users", art: "family"

      def self.save(ctx, params)
        return nil if params[:invite].blank?

        _invite, token = Invite.generate!(created_by: ctx.user, role: "member", site: ctx.site, site_role: "resident")
        ctx.data[:invite_url] = "#{ctx.base_url}/convite/#{token}" # só nesta resposta (nunca em flash)
        :stay
      end
    end
  end
end
