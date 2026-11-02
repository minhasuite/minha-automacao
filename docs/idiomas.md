# Idiomas (pt-BR, en, es)

- Textos em `config/locales/<área>.{pt-BR,en,es}.yml` (telas: `web`,
  `automations`, `integrations`, `helpers`, `dashboards`, `home`) e
  `config/locales/{pt-BR,en,es}.yml` (nomes de modelos e campos). Datas,
  números e mensagens padrão do Rails vêm do `rails-i18n`.
- `spec/i18n_spec.rb` falha se uma chave existir num idioma e faltar em outro,
  se o plural tiver formas diferentes ou se a interpolação (`%{x}`) mudar.
- `spec/i18n_coverage_spec.rb` falha se uma chave `t("...")` do código faltar
  em algum idioma ou se um plugin não trouxer en/es para cada texto pt-BR. No
  ambiente de teste, `raise_on_missing_translations` está ligado.
- Idioma da tela (`Localized`): o da pessoa (`users.dashboard_prefs["locale"]`,
  escolhido em Minha conta) → o do cookie `ma_locale` (seletor na entrada e na
  primeira configuração) → o do navegador (`Accept-Language`) → pt-BR.
- Texto novo: `t("area.chave")` na tela e a chave nos três arquivos. Chave
  terminada em `_html` pode ter HTML.
- Texto de plugin (integração, helper, widget, gatilho/condição/ação, tema,
  predefinição, ponte, fonte do Diário, provedor de IA/clima...) fica no
  próprio plugin, sem lista central: `extend PluginTexts` +
  `translates :title, :description` na base; o pt-BR vem do `describe` e o
  plugin traz `texts en: {...}, es: {...}` (mensagens próprias com
  `texts "pt-BR" => {...}` e `text(:chave, var: x)`).
- Rótulos de constantes (`Site::KINDS`, `Device::SITUATIONS`...) usam
  `LocalizedLabel` (traduz na hora de ler).

## Já traduzido

Todas as telas web, avisos (flash), e-mail de senha, páginas legais,
validações dos modelos e os textos dos plugins. App Flutter: `lib/l10n` do app.

## Falta

- Textos gravados no banco na hora (nomes padrão de pontos criados pelas
  integrações, passos do trace de automação, notas de importação do HA,
  títulos de disparo): ficam no idioma de quem gerou.
- Verbos da busca (só pt, com alguns verbos en/es; a voz já tem frases e
  respostas nos três idiomas desde a ondaB1), manifesto PWA, erros da API `/api/v1` e erros técnicos de
  drivers/supervisor/backups.
- Broadcast Turbo renderizado fora de uma requisição sai em pt-BR.
