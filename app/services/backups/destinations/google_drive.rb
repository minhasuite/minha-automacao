require "net/http"

module Backups
  module Destinations
    # Google Drive da conta do dono, conectado pela tela de Saúde (OAuth do
    # mesmo cliente Google da agenda, `GOOGLE_CLIENT_ID`/`SECRET`). Escopo
    # `drive.file`: o app só enxerga o que ele mesmo criou. As cópias vão para
    # a pasta FOLDER (criada se faltar). O refresh token fica cifrado com o
    # Active Record Encryption (as chaves das credenciais de integração) num
    # arquivo ao lado do estado do backup. Conectado, vira o destino.
    class GoogleDrive
      SCOPE = "https://www.googleapis.com/auth/drive.file".freeze
      API = "https://www.googleapis.com/drive/v3".freeze
      UPLOAD = "https://www.googleapis.com/upload/drive/v3/files".freeze
      REVOKE = "https://oauth2.googleapis.com/revoke".freeze
      FOLDER = "Minha Automação – Backups".freeze
      FOLDER_TYPE = "application/vnd.google-apps.folder".freeze
      URL = "gdrive://drive".freeze

      def self.owns?(uri) = uri.scheme == "gdrive"
      def self.label = "Google Drive"

      # A cópia é do banco do servidor inteiro: só o dono da primeira instalação (a da casa) liga.
      def self.manageable_by?(user) = user.owner? && user.tenant_id == Tenant.order(:created_at, :id).pick(:id)
      def self.state_for(user) = "backup_drive:#{user.id}"

      # --- token cifrado (mesma interface de Integration para Calendars::Google.access_token) ---

      def self.file = File.join(File.dirname(Backups.status_file), "backup-gdrive.json")

      def self.secrets
        JSON.parse(ActiveRecord::Encryption.encryptor.decrypt(File.read(file)))
      rescue Errno::ENOENT, JSON::ParserError, ActiveRecord::Encryption::Errors::Base
        {}
      end

      def self.merge_secrets!(values) = write!(secrets.merge(values.stringify_keys))
      def self.write!(data) = File.write(file, ActiveRecord::Encryption.encryptor.encrypt(JSON.generate(data)), perm: 0o600)
      def self.connected? = secrets["refresh_token"].present?
      def self.email = secrets["email"]

      # Volta do consentimento: guarda o refresh token e a conta (para a tela).
      def self.connect!(code, redirect_uri)
        tokens = Calendars::Google.exchange(code, redirect_uri)
        if tokens["refresh_token"].blank?
          raise Integrations::Error, "O Google não mandou a autorização permanente. Tire o acesso do app em myaccount.google.com/permissions e conecte de novo."
        end

        write!(tokens)
        merge_secrets!("email" => account_email)
      end

      def self.account_email
        new(URI(URL)).about.dig("user", "emailAddress")
      rescue Error, SafeHttp::Error
        nil # conectado; só a conta fica sem nome na tela
      end

      # Apaga o token daqui e revoga no Google (melhor esforço: sem rede, some só daqui).
      def self.disconnect!
        token = secrets["refresh_token"]
        FileUtils.rm_f(file)
        return unless token

        SafeHttp.request("POST", REVOKE, headers: { "Content-Type" => "application/x-www-form-urlencoded" }, body: URI.encode_www_form(token: token))
      rescue SafeHttp::Error
        nil
      end

      def initialize(_uri) = nil

      def describe
        copies = files.select { |f| NAME.match?(f["name"].to_s) }
        size = ActiveSupport::NumberHelper.number_to_human_size(copies.sum { |f| f["size"].to_i })
        "#{self.class.label}: #{self.class.email || 'conta conectada'} · #{copies.size} cópia(s), #{size}"
      rescue Error, Integrations::Error, SafeHttp::Error
        "#{self.class.label}: #{self.class.email || 'conta conectada'}"
      end

      def about = json("GET", "#{API}/about?fields=user(emailAddress)")

      # Envio resumable em um PUT só (sem limite de 5 MB do multipart). Reenvio troca o de mesmo nome.
      def upload(path, name)
        check!(name)
        files.select { |f| f["name"] == name }.each { |f| request("DELETE", "#{API}/files/#{f['id']}") }
        res = request("POST", "#{UPLOAD}?uploadType=resumable", body: { name: name, parents: [ folder ] },
                                                                headers: { "X-Upload-Content-Type" => "application/octet-stream" })
        location = Array(res.headers["location"]).first or raise Error, "Google Drive não abriu o envio"
        File.open(path, "rb") do |io|
          req = Net::HTTP::Put.new(URI(location), "Content-Type" => "application/octet-stream", "Content-Length" => File.size(path).to_s)
          req.body_stream = io
          stream(req)
        end
      end

      def list = files.map { |f| f["name"].to_s }.grep(NAME)
      def delete(name) = id(name).then { |i| request("DELETE", "#{API}/files/#{i}") }

      def download(name, path)
        File.open(path, "wb") do |out|
          stream(Net::HTTP::Get.new(URI("#{API}/files/#{id(name)}?alt=media"))) { |res| res.read_body { |c| out.write(c) } }
        end
      end

      private

      # ponytail: uma página (1000); a retenção mantém poucas cópias na pasta.
      def files
        q = "'#{folder}' in parents and trashed = false"
        json("GET", "#{API}/files?#{URI.encode_www_form(q: q, fields: 'files(id,name,size)', pageSize: 1000, spaces: 'drive')}")["files"].to_a
      end

      def id(name)
        check!(name)
        files.find { |f| f["name"] == name }&.dig("id") or raise Error, "#{name} não está no Google Drive"
      end

      def folder
        @folder ||= begin
          q = "name = '#{FOLDER}' and mimeType = '#{FOLDER_TYPE}' and trashed = false"
          found = json("GET", "#{API}/files?#{URI.encode_www_form(q: q, fields: 'files(id)', spaces: 'drive')}")["files"].to_a.first
          found ? found["id"] : json("POST", "#{API}/files", body: { name: FOLDER, mimeType: FOLDER_TYPE })["id"]
        end
      end

      def check!(name) = NAME.match?(name) || raise(Error, "nome inválido: #{name}")
      def token = @token ||= Calendars::Google.access_token(self.class)

      def json(...) = JSON.parse(request(...).body.presence || "{}")

      # Chamadas pequenas (JSON) pelo SafeHttp.
      def request(method, url, body: nil, headers: {})
        h = { "Authorization" => "Bearer #{token}" }.merge(headers)
        h["Content-Type"] = "application/json; charset=UTF-8" if body
        res = SafeHttp.request(method, url, headers: h, body: body && JSON.generate(body), timeout: 30)
        raise Error, "Google Drive respondeu #{res.status}: #{error(res)}" unless res.status.between?(200, 299)

        res
      end

      def error(res) = (JSON.parse(res.body).dig("error", "message") rescue nil) || res.body.to_s.truncate(120)

      # Arquivo inteiro (envio e download) direto no Net::HTTP, sem passar pela memória.
      def stream(req, &on_body)
        req["Authorization"] = "Bearer #{token}"
        Net::HTTP.start(req.uri.host, req.uri.port, use_ssl: true, open_timeout: 20, read_timeout: 300, write_timeout: 300) do |http|
          http.request(req) do |res|
            raise Error, "Google Drive respondeu #{res.code}" unless res.is_a?(Net::HTTPSuccess)

            on_body&.call(res)
          end
        end
      end
    end
  end
end
