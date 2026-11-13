require "open3"
require "zlib"

module Backups
  # Backup na hora, completo ou parcial (resto, 7.12; o "backup parcial" do
  # HA): `pg_dump` do banco deixando de fora os dados das partes não
  # marcadas (a estrutura vai sempre, então o restaurado sobe igual, só sem
  # aquele histórico). Vai para a pasta dos backups locais, aparece na lista
  # e restaura pelo mesmo caminho. Parte nova = uma linha em `PARTS`.
  module Partial
    PARTS = {
      "history" => %w[readings reading_rollups events commands],
      "runs" => %w[automation_runs assist_runs ai_calls ai_usages notifications],
      "recordings" => %w[camera_recordings],
      "logs" => %w[audit_events system_logs shadow_reports shadow_actions]
    }.freeze

    module_function

    def labels = PARTS.keys.index_with { |k| I18n.t("resto.backup.parts.#{k}") }

    # `skip` = partes que ficam de fora → nome do arquivo criado.
    def create!(skip: [], user: nil, dir: Backups.dir)
      skip = Array(skip).map(&:to_s) & PARTS.keys
      name = "ma-#{skip.empty? ? 'completo' : 'parcial'}-#{Time.current.strftime('%Y%m%d-%H%M%S')}.sql.gz"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, name)
      dump!(path, PARTS.values_at(*skip).flatten)
      AuditEvent.create!(tenant_id: user.tenant_id, user_id: user.id, action: "backup.create", auditable_type: "Backup", details: { file: name, skip: skip }) if user
      name
    rescue SystemCallError => e
      raise Error, I18n.t("resto.backup.failed", error: e.message)
    end

    def dump!(path, exclude)
      db = ActiveRecord::Base.connection_db_config.configuration_hash[:database].to_s
      tmp = "#{path}.tmp"
      # O próprio pg_dump comprime (formato texto + --compress = um .sql.gz igual ao do gzip):
      # o GzipWriter do Ruby às vezes levantava Zlib::BufError no meio da cópia.
      cmd = [ "pg_dump", "--no-owner", "--no-privileges", "--compress=6", "--file=#{tmp}", *exclude.map { |t| "--exclude-table-data=#{t}" } ]
      _out, err, status = Open3.capture3(Backups.pg_env(db), *cmd)
      raise Error, I18n.t("resto.backup.failed", error: err.strip.truncate(200)) unless status.success?
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if tmp
    end
  end
end
