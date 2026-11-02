module Onboarding
  module Steps
    # ondaA2 A15: instalação nova a partir de um backup (o "Restaurar de um
    # backup" da instalação do HA). Só sem ninguém cadastrado; o link fica no
    # passo de conta. Depois da restauração as contas voltam com o banco.
    class RestoreStep < Step
      describe key: "restore", icon: "refresh", art: "welcome"

      def self.side? = true
      def self.ready?(ctx) = ctx.user.nil? && Onboarding.fresh_install?
      def self.needs_site? = false
      def self.optional? = false
      def self.locals(_ctx) = { available: Backups::Restore.available?, status: Backups::Restore.status }

      def self.save(ctx, params)
        return I18n.t("backup_restore.errors.no_file") unless params[:file].respond_to?(:read)

        name = Backups::Restore.upload!(params[:file], passphrase: params[:passphrase])
        Backups::Restore.start!(name, source: "storage")
        ctx.notice = I18n.t("backup_restore.started")
        :stay
      rescue Backups::Error => e
        e.message
      end
    end
  end
end
