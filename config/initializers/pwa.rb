# Cores do PWA que precisam ser literais (o manifest e o <meta name="theme-color"> não leem
# var(--x)). Ficam aqui, fora de app/, espelhando os tokens da gem componentes_ui:
# - splash: o --side (fundo da moldura) — fundo da tela de abertura e cor do app instalado;
# - page_light: o --page do tema claro (a do escuro vem do ss_theme_color_tag da gem).
Rails.application.config.x.pwa = ActiveSupport::OrderedOptions.new.merge!(
  splash: "#17132e",
  page_light: "#f6f5fb"
)
