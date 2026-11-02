module Onboarding
  # Interface de um passo da primeira configuração. Título, texto e rótulos
  # vêm de `onboarding.<key>.*` nos arquivos de idioma.
  #
  # `save(ctx, params)` → nil (feito: vai para o próximo), :stay (mostra o
  # mesmo passo com `ctx.notice`/`ctx.data`) ou uma String (erro na tela).
  class Step
    class << self
      attr_reader :key, :icon, :art

      def describe(key:, icon:, art: key)
        @key = key
        @icon = icon
        @art = art
      end

      def title = I18n.t("onboarding.#{key}.title")
      def subtitle = I18n.t("onboarding.#{key}.subtitle", default: "")
      def partial = "web/onboarding/steps/#{key}"

      # Fora da lista desta pessoa (padrão: nunca).
      def skip?(_ctx) = false

      # Passo lateral: fora da ordem e da contagem, aberto só por link (ex.: restaurar backup).
      def side? = false

      # Dá para abrir agora? (padrão: com o dono logado e o local já criado)
      def ready?(ctx) = ctx.user.present? && (!needs_site? || ctx.site.present?)
      def needs_site? = true

      # Pode pular (botão "Agora não")?
      def optional? = true

      # Variáveis da partial.
      def locals(_ctx) = {}

      def save(_ctx, _params) = nil
    end
  end
end
