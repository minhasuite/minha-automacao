module Web
  # Configurações → Backups (ondaA2 A15): os backups locais e os de fora, com
  # "Restaurar", e enviar um arquivo de backup. Restaurar troca o banco do
  # servidor inteiro: só o dono, num servidor de uma instalação, digitando a
  # palavra de confirmação.
  class BackupsController < ApplicationController
    before_action { raise ActiveRecord::RecordNotFound unless Backups::Restore.allowed?(current_user) }

    def show
      @available = Backups::Restore.available?
      @status = Backups::Restore.status
      @local = Backups::Restore.local
      @offsite = Backups::Restore.offsite
    end

    def restore
      return redirect_to(settings_backups_path, alert: t("backup_restore.confirm_wrong")) unless params[:confirm].to_s.strip.casecmp?(t("backup_restore.word"))

      file, source = prepare
      Backups::Restore.start!(file, source: source, user: current_user)
      redirect_to settings_backups_path, notice: t("backup_restore.started")
    rescue Backups::Error => e
      redirect_to settings_backups_path, alert: e.message
    end

    # resto (7.12): backup agora, completo ou sem as partes desmarcadas.
    def create
      name = Backups::Partial.create!(skip: Backups::Partial::PARTS.keys - Array(params[:parts]), user: current_user)
      redirect_to settings_backups_path, notice: t("resto.backup.created", name: name)
    rescue Backups::Error => e
      redirect_to settings_backups_path, alert: e.message
    end

    private

    # Arquivo enviado vence; senão o escolhido na lista ("local:<nome>" ou "offsite:<nome>").
    def prepare
      kind, name = params[:pick].to_s.split(":", 2)
      if params[:file].respond_to?(:read) then [ Backups::Restore.upload!(params[:file], passphrase: params[:passphrase]), "storage" ]
      elsif kind == "offsite" then [ Backups::Restore.fetch_offsite!(name), "storage" ]
      else
        raise Backups::Error, t("backup_restore.errors.bad_name") unless Backups::Restore.local.any? { |f| f[:name] == name }

        [ name, "backups" ]
      end
    end
  end
end
