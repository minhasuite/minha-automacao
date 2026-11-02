require "open3"
require "shellwords"

module Backups
  # Destinos da cópia fora de casa. Destino novo = classe aqui (ou em outro
  # arquivo) com `self.owns?(uri)`, `self.label` e, por instância criada com a
  # URI, `upload(caminho, nome)`, `list` (nomes), `delete(nome)`,
  # `download(nome, caminho)` e `describe` (texto sem segredo) + nome em
  # `Backups::DESTINATIONS`.
  module Destinations
    # VPS ou qualquer servidor com SSH: `ssh://usuario@host[:porta]/pasta`
    # (aceita `sftp://`). Chave privada em `BACKUP_SSH_KEY_FILE` (padrão
    # /secrets/backup_ssh_key, montado só-leitura); o host conhecido é gravado
    # na primeira conexão (`accept-new`) em `BACKUP_SSH_KNOWN_HOSTS`.
    class Ssh
      def self.owns?(uri) = %w[ssh sftp].include?(uri.scheme)
      def self.label = "Servidor por SSH"

      def initialize(uri)
        @uri = uri
        raise Error, "informe usuário e host em BACKUP_OFFSITE_URL" if uri.user.blank? || uri.host.blank?

        @dir = uri.path.presence || "."
      end

      def describe = "#{self.class.label}: #{@uri.host}#{@dir}"

      def upload(path, name)
        ssh("mkdir -p #{q(@dir)}")
        run("scp", *opts("-P"), path, "#{target}:#{remote(name)}.tmp")
        ssh("mv -f #{q(remote(name))}.tmp #{q(remote(name))}")
      end

      def list = ssh("ls -1 #{q(@dir)}").lines.map(&:strip).grep(NAME)
      def delete(name) = ssh("rm -f -- #{q(remote(name))}")
      def download(name, path) = run("scp", *opts("-P"), "#{target}:#{remote(name)}", path)

      private

      def target = "#{@uri.user}@#{@uri.host}"

      def remote(name)
        raise Error, "nome inválido: #{name}" unless NAME.match?(name)

        File.join(@dir, name)
      end

      def q(s) = Shellwords.escape(s)

      def opts(port_flag)
        known = ENV.fetch("BACKUP_SSH_KNOWN_HOSTS") { Rails.root.join("storage", "backup_known_hosts").to_s }
        [ "-i", ENV.fetch("BACKUP_SSH_KEY_FILE", "/secrets/backup_ssh_key"), port_flag, (@uri.port || 22).to_s,
          "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=#{known}", "-o", "ConnectTimeout=20" ]
      end

      def ssh(command) = run("ssh", *opts("-p"), target, command)

      def run(*cmd)
        out, err, st = Open3.capture3(*cmd)
        raise Error, "#{cmd.first}: #{err.strip.lines.last.to_s.truncate(200)}" unless st.success?

        out
      end
    end

    # S3 compatível (Cloudflare R2, Backblaze B2, MinIO, AWS):
    # `s3://bucket/prefixo`, com `BACKUP_S3_ENDPOINT`, `BACKUP_S3_ACCESS_KEY_ID`,
    # `BACKUP_S3_SECRET_ACCESS_KEY` e `BACKUP_S3_REGION` (padrão auto).
    class S3
      def self.owns?(uri) = uri.scheme == "s3"
      def self.label = "Armazenamento S3"

      def initialize(uri)
        @bucket = uri.host.presence or raise Error, "informe o bucket em BACKUP_OFFSITE_URL"
        @prefix = uri.path.to_s.delete_prefix("/").then { |p| p.empty? || p.end_with?("/") ? p : "#{p}/" }
      end

      def describe = "#{self.class.label}: #{@bucket}/#{@prefix}"

      def upload(path, name) = client.put_object(bucket: @bucket, key: key(name), body: File.open(path, "rb"))
      def delete(name) = client.delete_object(bucket: @bucket, key: key(name))
      def download(name, path) = client.get_object(bucket: @bucket, key: key(name), response_target: path)

      def list
        client.list_objects_v2(bucket: @bucket, prefix: @prefix).each_page
              .flat_map { |page| page.contents.map { |o| o.key.delete_prefix(@prefix) } }.grep(NAME)
      end

      private

      def key(name)
        raise Error, "nome inválido: #{name}" unless NAME.match?(name)

        "#{@prefix}#{name}"
      end

      def client
        require "aws-sdk-s3"
        @client ||= Aws::S3::Client.new(
          endpoint: ENV["BACKUP_S3_ENDPOINT"].presence, region: ENV.fetch("BACKUP_S3_REGION", "auto"),
          access_key_id: ENV["BACKUP_S3_ACCESS_KEY_ID"], secret_access_key: ENV["BACKUP_S3_SECRET_ACCESS_KEY"],
          request_checksum_calculation: "when_required", response_checksum_validation: "when_required"
        )
      end
    end
  end
end
