module Billing
  # Credencial e pacote da Google Play (copiado do minhas-compras). Sem conta de
  # serviço a verificação fica desligada e nada é concedido (na dúvida, não
  # concede). Produção: PLAY_SERVICE_ACCOUNT_JSON (o JSON, do
  # MINHA_AUTOMACAO_PLAY_SERVICE_ACCOUNT_JSON da VPS); dev: ..._PATH.
  class PlayConfig
    SCOPE = "https://www.googleapis.com/auth/androidpublisher".freeze
    PACKAGE = "com.minhasuite.minhaautomacao".freeze

    def self.configured? = raw.present?
    def self.package = ENV["PLAY_PACKAGE_NAME"].presence || PACKAGE
    def self.plan_for(product_id) = Plans::PRODUCTS[product_id.to_s]
    def self.credentials_io = StringIO.new(raw)

    def self.raw
      inline = ENV["PLAY_SERVICE_ACCOUNT_JSON"].presence
      return inline if inline

      path = ENV["PLAY_SERVICE_ACCOUNT_JSON_PATH"].presence
      path && File.exist?(path) ? File.read(path) : nil
    end
  end
end
