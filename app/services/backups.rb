require "open3"
require "zlib"

# Cópia fora de casa (G20). O `pg_dump` diário continua no serviço `backup`
# do compose (pasta `BACKUP_DIR`); aqui o worker pega o mais novo, cifra
# (formato do `openssl enc -aes-256-cbc -pbkdf2`, então dá para abrir sem o
# app) e manda para um destino plugável. Destino = classe em
# `Backups::Destinations` com `owns?(uri)` + nome em `DESTINATIONS`
# (`upload`, `list`, `delete`, `download`, `describe`); nada muda aqui.
# O teste de restauração baixa a cópia mais nova, restaura num banco
# temporário e confere as contagens com o banco vivo.
#
# Sem `BACKUP_OFFSITE_URL` e `BACKUP_PASSPHRASE` fica desligado (a tela de
# saúde avisa). Runbook em docs/backup.md.
module Backups
  DESTINATIONS = %w[Ssh S3 GoogleDrive].freeze
  LATE = 26.hours
  RESTORE_LATE = 8.days
  ITER = 200_000
  # Tabelas conferidas no teste de restauração (sem tenant: SQL direto).
  TABLES = %w[tenants users sites devices points automations dashboards].freeze
  NAME = /\A[\w.-]+\z/

  class Error < StandardError; end

  module_function

  def dir = ENV.fetch("BACKUP_DIR", "/backups")
  # Google Drive conectado pela tela vence o `BACKUP_OFFSITE_URL`.
  def url = Destinations::GoogleDrive.connected? ? Destinations::GoogleDrive::URL : ENV["BACKUP_OFFSITE_URL"].presence
  def passphrase = ENV["BACKUP_PASSPHRASE"].presence
  def keep = [ ENV.fetch("BACKUP_OFFSITE_KEEP", "14").to_i, 1 ].max
  def configured? = !url.nil? && !passphrase.nil?

  def destinations = DESTINATIONS.map { |n| Destinations.const_get(n) }

  def destination(address = url)
    uri = URI.parse(address.to_s)
    klass = destinations.find { |d| d.owns?(uri) } or raise Error, "destino de backup desconhecido: #{uri.scheme}"
    klass.new(uri)
  rescue URI::InvalidURIError
    raise Error, "BACKUP_OFFSITE_URL inválido"
  end

  def latest_dump = Dir.glob(File.join(dir, "*.sql.gz")).max_by { |f| File.mtime(f) }

  # Estado da última cópia e do último teste (arquivo no volume `storage`: é do servidor, não da instalação).
  def status_file = ENV.fetch("BACKUP_STATUS_FILE") { Rails.root.join("storage", "backup-offsite.json").to_s }

  def status
    JSON.parse(File.read(status_file))
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end

  def save_status!(patch)
    data = status.merge(patch.transform_values { |v| v.respond_to?(:iso8601) ? v.iso8601 : v })
    File.write(status_file, JSON.generate(data))
    data
  end

  def time(key) = (v = status[key]) && Time.zone.parse(v)

  # Cópia de hoje ok e sem erro depois dela.
  def offsite_ok?(now = Time.current)
    at = time("uploaded_at")
    !at.nil? && at > now - LATE && !failed_after?("error_at", at)
  end

  def restore_ok?(now = Time.current)
    at = time("restored_at")
    !at.nil? && at > now - RESTORE_LATE && !failed_after?("restore_error_at", at)
  end

  def failed_after?(key, at) = (err = time(key)) && err >= at

  # Manda o dump mais novo (se ainda não foi) e aplica a retenção. Erro vai para o estado, não para a fila.
  def offsite!(now: Time.current, force: false)
    return unless configured?

    dump = latest_dump or raise Error, "nenhum backup local em #{dir}"
    name = "#{File.basename(dump)}.enc"
    return if !force && status["file"] == name && status["error_at"].nil?

    dest = destination
    Dir.mktmpdir("ma-backup") do |tmp|
      enc = File.join(tmp, name)
      File.open(dump, "rb") { |i| File.open(enc, "wb") { |o| encrypt(i, o) } }
      dest.upload(enc, name)
      removed = prune!(dest)
      save_status!("uploaded_at" => now, "file" => name, "size" => File.size(enc), "destination" => dest.describe,
                   "removed" => removed, "error" => nil, "error_at" => nil)
    end
  rescue StandardError => e
    save_status!("error" => e.message.truncate(300), "error_at" => now)
    nil
  end

  # Fica com as `keep` mais novas (o nome leva a data: ordem do nome = ordem do tempo).
  def prune!(dest)
    old = dest.list.grep(/\.enc\z/).sort[0...-keep] || []
    old.each { |n| dest.delete(n) }
    old.size
  end

  # Baixa a cópia externa mais nova, restaura num banco temporário e confere as contagens.
  def restore_test!(now: Time.current)
    return unless configured?

    dest = destination
    name = dest.list.grep(/\.enc\z/).max or raise Error, "nenhuma cópia no destino"
    counts = Dir.mktmpdir("ma-restore") do |tmp|
      enc = File.join(tmp, name)
      dest.download(name, enc)
      restore_into_temp_db(enc)
    end
    live = live_counts
    bad = TABLES.reject { |t| close?(counts[t].to_i, live[t].to_i) }
    raise Error, "contagens diferentes: #{bad.map { |t| "#{t} #{counts[t]}/#{live[t]}" }.join(', ')}" if bad.any?

    save_status!("restored_at" => now, "restored_file" => name, "restore_counts" => counts, "restore_error" => nil, "restore_error_at" => nil)
  rescue StandardError => e
    save_status!("restore_error" => e.message.truncate(300), "restore_error_at" => now)
    nil
  end

  # ponytail: tolerância fixa (5 linhas ou 10%), porque o banco vivo anda desde o dump; trocar por contagem gravada no dump se precisar de exatidão.
  def close?(restored, live) = (restored - live).abs <= [ 5, live / 10 ].max && (live.zero? || restored.positive?)

  def live_counts = TABLES.to_h { |t| [ t, ActiveRecord::Base.connection.select_value(Arel::Table.new(t).project(Arel.star.count).to_sql).to_i ] }

  def restore_into_temp_db(enc_path)
    db = "ma_restore_#{SecureRandom.hex(4)}"
    admin { |c| c.exec("CREATE DATABASE #{db}") }
    env = pg_env(db)
    Open3.popen2e(env, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-o", "/dev/null") do |stdin, out, wait|
      reader = Thread.new { out.read }
      reader.report_on_exception = false
      File.open(enc_path, "rb") do |f|
        decrypt_stream(f) do |gz|
          Zlib::GzipReader.wrap(gz) { |sql| sql.each_line { |l| stdin.write(l) unless l.start_with?("\\restrict", "\\unrestrict") } }
        end
      end
      stdin.close
      raise Error, "psql: #{reader.value.to_s.lines.last(3).join.strip.truncate(200)}" unless wait.value.success?
    end
    TABLES.to_h { |t| [ t, psql_value(env, "SELECT count(*) FROM #{t}").to_i ] }
  ensure
    admin { |c| c.exec("DROP DATABASE IF EXISTS #{db} WITH (FORCE)") } if db
  end

  def psql_value(env, sql)
    out, err, st = Open3.capture3(env, "psql", "-X", "-At", "-c", sql)
    raise Error, "psql: #{err.strip.truncate(200)}" unless st.success?

    out.strip
  end

  # Senha pelo ambiente do processo filho, nunca na linha de comando.
  def pg_env(database)
    c = ActiveRecord::Base.connection_db_config.configuration_hash
    { "PGHOST" => c[:host].to_s, "PGPORT" => c[:port].to_s, "PGUSER" => c[:username].to_s, "PGPASSWORD" => c[:password].to_s,
      "PGDATABASE" => database }.compact_blank
  end

  # Conexão à parte (CREATE DATABASE não roda dentro de transação).
  def admin
    c = ActiveRecord::Base.connection_db_config.configuration_hash
    conn = PG.connect(host: c[:host], port: c[:port], user: c[:username], password: c[:password], dbname: c[:database])
    yield conn
  ensure
    conn&.close
  end

  # --- cifra compatível com `openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256` ---

  def encrypt(input, output, pass = passphrase)
    salt = SecureRandom.random_bytes(8)
    cipher = cipher(:encrypt, pass, salt)
    output.write("Salted__", salt)
    while (chunk = input.read(1 << 16))
      output.write(cipher.update(chunk))
    end
    output.write(cipher.final)
  end

  def decrypt(input, output, pass = passphrase) = decrypt_stream(input, pass) { |io| IO.copy_stream(io, output) }

  # Entrega um IO com o texto aberto (pipe), sem gravar o dump decifrado no disco.
  def decrypt_stream(input, pass = passphrase)
    head = input.read(16).to_s
    raise Error, "arquivo não é uma cópia cifrada" unless head.start_with?("Salted__") && head.bytesize == 16

    cipher = cipher(:decrypt, pass, head.byteslice(8, 8))
    rd, wr = IO.pipe
    rd.binmode
    wr.binmode
    writer = Thread.new do
      while (chunk = input.read(1 << 16))
        wr.write(cipher.update(chunk))
      end
      wr.write(cipher.final)
    rescue OpenSSL::Cipher::CipherError
      raise Error, "senha do backup errada ou arquivo corrompido"
    ensure
      wr.close
    end
    writer.report_on_exception = false
    result = yield rd
    writer.value
    result
  ensure
    rd&.close
  end

  def cipher(mode, pass, salt)
    raise Error, "BACKUP_PASSPHRASE vazio" if pass.blank?

    key_iv = OpenSSL::PKCS5.pbkdf2_hmac(pass, salt, ITER, 48, "sha256")
    c = OpenSSL::Cipher.new("aes-256-cbc").public_send(mode)
    c.key = key_iv[0, 32]
    c.iv = key_iv[32, 16]
    c
  end
end
