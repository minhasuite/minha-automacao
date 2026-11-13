module Diagnostics
  # Um reparo seguro oferecido por um achado. Três jeitos (`kind`):
  #   :action → botão que chama `call(finding, user:, params:)` → mensagem;
  #   :link   → leva a outra tela (`url(finding)`), que faz o resto;
  #   :form   → botão com um campo (`options(finding, ctx)`: escolher a área).
  # `role` = papel mínimo no local (:manage = técnico+; :command = quem pode
  # mandar comando sensível, como o "Reconectar" da página do aparelho).
  # `confirm: true` pede confirmação (`danger: true` = vermelha).
  # Nenhum reparo comanda aparelho: ler de novo, varrer, mudar cadastro ou apagar cadastro.
  class Fix
    extend PluginTexts
    translates :label

    class << self
      attr_reader :key, :icon, :kind, :role

      def describe(key:, label:, icon:, kind: :action, role: :manage, confirm: false, danger: false)
        @key = key
        @label = label
        @icon = icon
        @kind = kind
        @role = role
        @confirm = confirm
        @danger = danger
      end

      def confirm? = @confirm == true
      def danger? = @danger == true

      # O papel no local deixa? (`:command` = comando sensível, como na página do aparelho)
      def allowed?(site_role) = SiteMembership.allowed?(site_role, role, risk: (role == :command ? "sensitive" : nil))

      def available?(_finding, _ctx) = true
      def url(_finding) = nil
      def options(_finding, _ctx) = []
      def call(_finding, user:, params: {}) = raise(NotImplementedError)

      def routes = Rails.application.routes.url_helpers
    end

    texts "pt-BR" => { confirm: "%{label}: %{name}?" },
          en: { confirm: "%{label}: %{name}?" },
          es: { confirm: "%{label}: %{name}?" }
  end
end
