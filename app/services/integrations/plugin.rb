module Integrations
  # Interface comum de um tipo de integração. Subclasse = plugin: descreve-se
  # (`describe`), monta a integração pelo assistente (`setup`), refaz o
  # login (`login`/`connect_locals`/`logged_in?`) e varre a conta
  # (`inventory`, no formato descrito em `Integrations`). As telas usam as
  # partials `web/integrations/forms/_<key>` (assistente e Reconfigurar) e
  # `web/integrations/connect/_<key>` (passo de login com QR, se houver).
  #
  # Todo passo devolve um `Outcome`: para onde a tela vai (:found = lista de
  # encontrados, :connect = passo de login, :index, :devices ou :form =
  # formulário de novo com o erro), com a integração e o aviso.
  class Plugin
    Outcome = Data.define(:to, :integration, :notice, :alert, :params) do
      def initialize(to:, integration: nil, notice: nil, alert: nil, params: {}) = super
    end

    class << self
      attr_reader :key, :title, :icon, :description, :driver

      def describe(key:, title:, icon:, description:, driver: key)
        @key = key
        @title = title
        @icon = icon
        @description = description
        @driver = driver
      end

      def outcome(to, **) = Outcome.new(to: to, **)

      # Assistente: formulário (params) → Outcome.
      def setup(_site, _form) = raise(NotImplementedError)

      # Reconfigurar: mesmo formulário sobre a integração que já existe.
      def login(integration, _form) = outcome(:connect, integration: integration)
      def reconfigurable? = true

      # Variáveis da tela de login (QR etc.). Erro do serviço: Integrations::Error.
      def connect_locals(_integration, _params) = {}

      # A tela de login pergunta a cada 3 s; true = logou (e a varredura já está na fila).
      def logged_in?(_integration) = false

      def inventory(_integration) = raise(NotImplementedError)

      # Plugin com varredura própria (não usa o inventário genérico).
      def custom_sync? = false

      # Retorno do OAuth (`/integracoes/oauth/retorno`, params com code e redirect_uri) → Outcome.
      def oauth_callback(integration, _params) = outcome(:connect, integration: integration, alert: "Esta integração não usa login externo.")

      # A cada minuto (Integrations.tick); padrão: nada.
      def tick(_now) = nil

      # Segredo gravado no aparelho adotado (local_key, token…).
      def device_secret(_integration, entry) = entry["secret"].presence

      # A primeira varredura vem do login (polled_at agora: a periódica não corre antes dele).
      def new_integration(site, **attrs) = site.integrations.new(driver: driver, name: title, poll_s: Integration::SYNC_S, polled_at: Time.current, **attrs)
    end
  end
end
