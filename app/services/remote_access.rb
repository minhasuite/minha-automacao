# Acesso remoto gerenciado (produto, base): como a casa é vista de fora. Cada
# jeito é um provedor (`RemoteAccess::Provider`) registrado em `PROVIDERS`:
# hoje o túnel da Cloudflare com o token colado na tela; o relay próprio da
# MinhaSuite (um subdomínio por cliente) entra aqui depois, sem mudar a tela
# (desenho em docs/remote-access.md). Quem roda o túnel é o supervisor
# (`/system/remote`); o túnel manual do compose (perfil `tunnel`, .env) tem
# prioridade e aparece como "configurado no servidor".
#
# Estado em `tenants.settings["remote_access"]` = {provider, enabled, url,
# secret (cifrado com as chaves do Active Record Encryption)}.
module RemoteAccess
  PROVIDERS = %w[CloudflareTunnel].freeze
  Error = Class.new(StandardError)

  module_function

  def providers = PROVIDERS.map { |n| const_get(n) }
  def provider(key) = providers.find { |p| p.key == key.to_s }
  def settings(tenant) = tenant.settings["remote_access"] || {}

  def seal(text) = ActiveRecord::Encryption.encryptor.encrypt(text.to_s)
  def unseal(text) = text.present? ? ActiveRecord::Encryption.encryptor.decrypt(text) : nil

  def save!(tenant, data) = tenant.update!(settings: tenant.settings.merge("remote_access" => settings(tenant).merge(data)))

  # Estado para a tela: o salvo + o que o supervisor vê (nil = sem supervisor ou fora do ar).
  def status(tenant)
    s = settings(tenant)
    live = (Apps::Supervisor.request(:get, "/system/remote")["data"] if Apps::Supervisor.configured?)
    { "provider" => s["provider"], "enabled" => s["enabled"] == true, "url" => s["url"], "live" => live }
  rescue Apps::Supervisor::Error
    { "provider" => s["provider"], "enabled" => s["enabled"] == true, "url" => s["url"], "live" => nil, "offline" => true }
  end

  def enable!(tenant, key, form)
    p = provider(key) or raise Error, I18n.t("remote.unknown")

    p.enable!(tenant, form)
  rescue Apps::Supervisor::Error => e
    raise Error, e.message
  end

  def disable!(tenant)
    provider(settings(tenant)["provider"])&.disable!(tenant)
    save!(tenant, "enabled" => false)
  rescue Apps::Supervisor::Error => e
    raise Error, e.message
  end

  # Interface de um provedor: `describe`, `fields` ([{key, secret}], rótulos em
  # `remote.<key>.fields.<campo>`), `enable!(tenant, form)` e `disable!(tenant)`.
  class Provider
    class << self
      attr_reader :key, :icon

      def describe(key:, icon:)
        @key = key
        @icon = icon
      end

      def label = I18n.t("remote.#{key}.label")
      def description = I18n.t("remote.#{key}.description")
      def fields = []
      def enable!(_tenant, _form) = raise(NotImplementedError)
      def disable!(_tenant) = nil
    end
  end

  # Cloudflare Tunnel: a pessoa cria o túnel no painel da Cloudflare (Zero
  # Trust → Tunnels), aponta o hostname para http://web:3000 e cola o token.
  class CloudflareTunnel < Provider
    describe key: "cloudflare", icon: "cloud"
    TOKEN = %r{\A[A-Za-z0-9_.=+/-]{20,4096}\z}

    def self.fields = [ { "key" => "token", "secret" => true }, { "key" => "url", "secret" => false } ]

    def self.enable!(tenant, form)
      saved = RemoteAccess.unseal(RemoteAccess.settings(tenant)["secret"])
      token = form[:token].to_s.strip.presence || saved
      raise Error, I18n.t("remote.cloudflare.bad_token") unless token.to_s.match?(TOKEN)

      url = form[:url].to_s.strip
      raise Error, I18n.t("remote.bad_url") if url.present? && !url.match?(%r{\Ahttps://[\w.-]+\z})
      raise Error, I18n.t("remote.no_supervisor") unless Apps::Supervisor.configured?

      Apps::Supervisor.request(:post, "/system/remote", { provider: key, token: token })
      RemoteAccess.save!(tenant, "provider" => key, "enabled" => true, "url" => url.presence, "secret" => RemoteAccess.seal(token))
    end

    def self.disable!(_tenant)
      Apps::Supervisor.request(:delete, "/system/remote") if Apps::Supervisor.configured?
    end
  end
end
