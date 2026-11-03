require "net/http"

module Backups
  module Destinations
    # OneDrive (catalogo): a pasta do app na conta Microsoft conectada pela
    # integração OneDrive (Integrations::OnedrivePlugin, token renovado por
    # ela). Envio grande por sessão de upload do Graph, em pedaços de 10 MiB.
    class Onedrive
      URL = "onedrive://approot".freeze
      CHUNK = 32 * 320 * 1024 # múltiplo de 320 KiB, como o Graph pede

      def self.owns?(uri) = uri.scheme == "onedrive"
      def self.label = "OneDrive"
      def self.integration = Integrations::OnedrivePlugin.backup_integration
      def self.connected? = !integration.nil?

      def initialize(_uri)
        @integration = self.class.integration or raise Error, "OneDrive não conectado"
      end

      def plugin = Integrations::OnedrivePlugin
      def api(method, url, body = nil) = ActsAsTenant.with_tenant(@integration.tenant) { plugin.api(@integration, method, url, body) }

      def describe
        copies = files.select { |f| NAME.match?(f["name"].to_s) }
        "#{self.class.label}: #{copies.size} cópia(s), #{ActiveSupport::NumberHelper.number_to_human_size(copies.sum { |f| f['size'].to_i })}"
      rescue Integrations::Error
        self.class.label
      end

      def upload(path, name)
        check!(name)
        session = api(:post, "#{Integrations::OnedrivePlugin::GRAPH}/special/approot:/#{ERB::Util.url_encode(name)}:/createUploadSession",
                      { item: { "@microsoft.graph.conflictBehavior" => "replace" } })
        uri = URI(session["uploadUrl"].to_s)
        total = File.size(path)
        File.open(path, "rb") do |io|
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 300, write_timeout: 300) do |http|
            offset = 0
            while (chunk = io.read(CHUNK))
              req = Net::HTTP::Put.new(uri, "Content-Length" => chunk.bytesize.to_s, "Content-Range" => "bytes #{offset}-#{offset + chunk.bytesize - 1}/#{total}")
              req.body = chunk
              res = http.request(req)
              raise Error, "OneDrive respondeu #{res.code}" unless res.is_a?(Net::HTTPSuccess)

              offset += chunk.bytesize
            end
          end
        end
      end

      def list = files.map { |f| f["name"].to_s }.grep(NAME)
      def delete(name) = api(:delete, "#{Integrations::OnedrivePlugin::GRAPH}/items/#{id(name)}")

      def download(name, path)
        token = ActsAsTenant.with_tenant(@integration.tenant) { plugin.access_token(@integration) }
        uri = URI("#{Integrations::OnedrivePlugin::GRAPH}/items/#{id(name)}/content")
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(Net::HTTP::Get.new(uri, "Authorization" => "Bearer #{token}")) }
        uri = URI(res["location"].to_s) if res.is_a?(Net::HTTPRedirection)
        File.open(path, "wb") do |out|
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 300) do |h|
            h.request(Net::HTTP::Get.new(uri)) do |r|
              raise Error, "OneDrive respondeu #{r.code}" unless r.is_a?(Net::HTTPSuccess)

              r.read_body { |c| out.write(c) }
            end
          end
        end
      end

      private

      # ponytail: uma página (200); a retenção mantém poucas cópias na pasta.
      def files = Array(api(:get, "#{Integrations::OnedrivePlugin::GRAPH}/special/approot/children?$select=id,name,size&$top=200")["value"])

      def id(name)
        check!(name)
        files.find { |f| f["name"] == name }&.dig("id") or raise Error, "#{name} não está no OneDrive"
      end

      def check!(name) = NAME.match?(name) || raise(Error, "nome inválido: #{name}")
    end
  end
end
