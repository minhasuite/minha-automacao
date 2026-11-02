# Idiomas (pt-BR, en, es)

- Textos em `config/locales/web.{pt-BR,en,es}.yml` (telas) e
  `config/locales/{pt-BR,en,es}.yml` (nomes de modelos e campos). Datas,
  números e mensagens padrão do Rails vêm do `rails-i18n`.
- `spec/i18n_spec.rb` falha se uma chave existir num idioma e faltar em outro,
  se o plural tiver formas diferentes ou se a interpolação (`%{x}`) mudar.
- Idioma da tela (`Localized`): o da pessoa (`users.dashboard_prefs["locale"]`,
  escolhido em Minha conta) → o do cookie `ma_locale` (seletor na entrada e na
  primeira configuração) → o do navegador (`Accept-Language`) → pt-BR.
- Texto novo: `t("area.chave")` na tela e a chave nos três arquivos. Chave
  terminada em `_html` pode ter HTML.

## Já traduzido

Layouts (app, entrada, primeira configuração), menu lateral, cabeçalho e
avisos, entrar / criar conta / esqueci a senha, Início sem local, primeira
configuração inteira, painéis (lista, novo, painel aberto), dispositivos
(lista, página, formulário), Configurações (moldura, Minha conta, Sistema com
a atualização, Acesso remoto, Plano) e os avisos desses controllers.

## Falta (próximas levas)

- Editor de painel, widgets e quiosque (`web/dashboards/edit`, `_widget_form`,
  `_layout_editor`, `_kiosk`, `widgets/*`) — estão com o agente de UI.
- Locais e áreas (`web/sites`, `web/areas`), pontos (`web/points`), Diário,
  Histórico, Mapa, Alertas, Notificações, Perguntar à casa.
- Automações, scripts, cenas, blueprints, regras simples, sombra, ferramentas.
- Integrações (catálogo, assistente, formulários `forms/_*`), helpers, dados,
  pacotes, aplicativos, IA, Saúde, Pessoas, Chaves de integração, Meus aparelhos.
- Textos que vêm do código: `describe` dos plugins (integrações, helpers,
  gatilhos/condições/ações, widgets, temas), mensagens de validação dos
  plugins, rótulos em constantes (`Site::KINDS`, `Area::KINDS`,
  `Device::SITUATIONS`, `SiteMembership` papéis), notificações e push, e-mails.
- Conteúdo gerado: títulos e rótulos do painel automático (`Dashboards::Generator`:
  "Luzes", "Agora", "Ligado"…) e dos widgets.
- App Flutter (tem o próprio `l10n`).
