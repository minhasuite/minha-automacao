module Backups
  # Restaurar pela tela e na primeira configuração (ondaA2 A15). O banco
  # inteiro volta para o backup escolhido: um dump local (`BACKUP_DIR`), uma
  # cópia de fora (baixada e aberta com a senha do backup) ou um arquivo
  # enviado (.sql.gz ou .enc com a senha). O arquivo aberto vai para
  # `storage/restore/` e o supervisor roda o bin/ma-restore à parte (guarda o
  # banco atual antes e volta para ele se o restaurado não subir).
  module Restore
    STATUS_FILE = "restore-status.json".freeze
    MAX_MB = 2048

    module_function

    def dir = Rails.root.join("storage", "restore").to_s
    def available? = Apps::Supervisor.configured?

    # O banco é do servidor inteiro: só o dono, e só num servidor de uma instalação.
    def allowed?(user) = user&.owner? && Tenant.count == 1

    def local = Dir.glob(File.join(Backups.dir, "*.sql.gz")).sort.reverse.map { |f| { name: File.basename(f), size: File.size(f), at: File.mtime(f) } }

    def offsite
      Backups.configured? ? Backups.destination.list.grep(/\.enc\z/).sort.reverse : []
    rescue Backups::Error, StandardError => e
      Rails.logger.warn("[backup] lista da cópia de fora: #{e.message}")
      []
    end

    def status
      JSON.parse(File.read(File.join(Backups.dir, STATUS_FILE)))
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end

    def running? = status["state"] == "running"

    # Arquivo enviado (IO) → nome em storage/restore, aberto e conferido.
    def upload!(io, passphrase: nil)
      raise Error, I18n.t("backup_restore.errors.too_big", mb: MAX_MB) if io.size > MAX_MB.megabytes

      store!(io, passphrase.presence || Backups.passphrase)
    end

    # Cópia de fora → baixa, abre com a senha do backup e guarda.
    def fetch_offsite!(name)
      raise Error, I18n.t("backup_restore.errors.bad_name") unless name.to_s.match?(NAME) && offsite.include?(name)

      Dir.mktmpdir("ma-restore") do |tmp|
        enc = File.join(tmp, name)
        Backups.destination.download(name, enc)
        File.open(enc, "rb") { |f| store!(f, Backups.passphrase) }
      end
    end

    def store!(io, pass)
      FileUtils.mkdir_p(dir)
      name = "restaurar-#{Time.current.strftime('%Y%m%d-%H%M%S')}.sql.gz"
      path = File.join(dir, name)
      head = io.read(8).to_s
      io.rewind
      File.open(path, "wb") do |out|
        if head == "Salted__"
          raise Error, I18n.t("backup_restore.errors.need_pass") if pass.blank?

          begin
            Backups.decrypt(io, out, pass)
          rescue Error
            raise Error, I18n.t("backup_restore.errors.bad_pass")
          end
        else
          IO.copy_stream(io, out)
        end
      end
      begin
        check!(path)
      rescue Error
        # Senha errada às vezes passa no padding do CBC (~1 em 256) e sai lixo.
        raise Error, I18n.t("backup_restore.errors.bad_pass") if head == "Salted__"

        raise
      end
      name
    rescue Error
      FileUtils.rm_f(path) if path
      raise
    end

    # Tem de ser um dump do pg_dump em gzip (o cabeçalho diz "PostgreSQL database dump").
    def check!(path)
      ok = Zlib::GzipReader.open(path) { |gz| gz.read(4096).to_s.include?("PostgreSQL database dump") }
      raise Error, I18n.t("backup_restore.errors.not_dump") unless ok
    rescue Zlib::Error
      raise Error, I18n.t("backup_restore.errors.not_dump")
    end

    # source: "backups" (dump local) ou "storage" (enviado/baixado).
    def start!(file, source:, user: nil)
      raise Error, I18n.t("backup_restore.errors.bad_name") unless file.to_s.match?(NAME) && %w[backups storage].include?(source)
      raise Error, I18n.t("backup_restore.errors.running") if running?

      AuditEvent.create!(tenant_id: user.tenant_id, user_id: user.id, action: "backup.restore", auditable_type: "Backup", details: { file: file, source: source }) if user
      Apps::Supervisor.request(:post, "/system/restore", { file: file, source: source })
    rescue Apps::Supervisor::Error => e
      raise Error, e.message
    end
  end
end
