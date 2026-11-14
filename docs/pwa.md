# PWA no iPhone (e no Android/computador)

Enquanto não há app iOS (o Flutter é só Android), o iPhone usa a web instalada na Tela de Início.
Push e canais em `docs/push.md`; aqui o que faz a PWA funcionar bem no WebKit.

## Instalar

- iOS não tem `beforeinstallprompt`. **Configurações → Aparência → "Instalar o app"** (`#instalar`,
  `web/pwa/_install_section`) mostra o que vale no aparelho: "já instalado" (standalone), o passo a passo
  do iPhone (Compartilhar → Adicionar à Tela de Início) ou, no Android/computador, o botão que chama o
  pedido do navegador (guardado em `application.js` como `window.maInstallPrompt`).
- **Início**: aviso discreto (`web/pwa/_install_notice`, `Ss::NoticeCardComponent` dispensável) só no
  Safari do iPhone fora do app; "Agora não" grava `localStorage["ma-install-notice"] = "off"` (deste
  aparelho). Nunca aparece no app Android (`AppScreen`) nem no quiosque.
- Detecção em `controllers/pwa/platform.js` (`standalone()`: `display-mode: standalone` ou
  `navigator.standalone`; `ios()`: iPhone/iPad, inclusive o iPad que se diz Macintosh).
- Instalar e push exigem https: na casa, só pelo acesso externo.

## Tela

- `viewport-fit=cover` nos layouts `application`, `auth` e `onboarding`; a moldura da gem respeita o
  `env(safe-area-inset-*)` (topo, laterais deitado e barra de gestos; `safe_area_web.css` da gem desde o
  branch `pwa-ios`; o FAB "Falar com a casa" e a folha de baixo já respeitavam).
- **Barra de status = `default`** (decisão): o `black-translucent` deixa o relógio sempre branco e ele
  some sobre o topo claro do tema claro. Com `default` o iOS pinta a barra com o `theme-color` (o `--page`
  do tema, acertado pelo `_theme_head`) e o texto acompanha; a área segura do topo fica 0.
- Sem splash próprio (`apple-touch-startup-image` pede uma imagem por tamanho de tela): o iPhone mostra o
  fundo até a página carregar.
- Manifesto (`Web::PwaController#manifest`) no idioma de quem pede, com `shortcuts` (Câmeras, Falar com a
  casa = `/?falar=1`, Notificações; o iPhone ignora), `categories` e ícone `maskable` (a casa do
  `icon-512` cabe no círculo de 80%, o degradê vai até a borda). Sem `screenshots` (precisariam de dados
  de exemplo; não vale a manutenção).

## Service worker (`app/views/pwa/service-worker.js.erb`)

- `VERSION` = hash da versão do app (`RELEASE_TAG`/`APP_VERSION`), do CSS digerido e do idioma: mudou, o
  navegador vê o arquivo novo, instala e apaga o cache antigo (`ma-offline-*`).
- Guarda só `/sem-conexao` (página pública, sem sessão nem dado da casa), o CSS dela e o ícone.
  Navegação vai sempre à rede (com `navigationPreload` onde houver); sem rede, "Sem conexão com a casa".
  Nada de página, API, quadro de câmera ou dado da casa em cache.
- Push: mostra sempre uma notificação (o WebKit exige `userVisibleOnly`), ícone/badge do servidor; o
  iPhone ignora botões, imagem e `requireInteraction` (o toque abre o link). O payload do Web Push leva
  `unread` (não lidos da pessoa, `Push::Browser`) e o SW põe o selo do ícone (`setAppBadge`/`clearAppBadge`,
  iOS 16.4+ instalado, Chrome/Edge instalado); a página acerta o selo pelo `<meta name="ma-unread">`.
- Push no iPhone só com o app na Tela de Início e permissão pedida no toque: Meus aparelhos explica isso no
  Safari comum (`push.ios_install`) e no iPhone sem Web Push (`push.ios_old`) em vez de ficar calada.

## Câmeras

`camera_controller.js`: WebRTC → MSE (no iPhone o `ManagedMediaSource`, iOS 17.1+, com
`disableRemotePlayback`) → **HLS nativo** (`.m3u8` assinado, `<video playsinline>`). Agora o MSE que falha
antes de tocar (codec, `addSourceBuffer`, WebSocket que fecha, 12 s sem vídeo) cai para o HLS quando o
navegador toca HLS (Safari), em vez de voltar às fotos; o `play()` recusado por falta de gesto (vídeo com
som) tenta de novo sem som; tela cheia no iPhone é a do `<video>` (`webkitEnterFullscreen`).

## Voz

- `voice/wav_recorder.js`: o `AudioContext` nasce e acorda (`resume`) dentro do toque, antes do
  `getUserMedia` (senão o iOS grava silêncio), na taxa do aparelho, e o WAV sai em 16 kHz por média de janela.
  O servidor continua aceitando m4a/webm (ffmpeg no `Wyoming.pcm_of`).
- "Falar com a casa": o `<audio>` da resposta é destravado com um silêncio curto no toque de gravar ou
  mandar; se o navegador recusar mesmo assim, o tocador aparece com "Toque no play".

## Sessão

- O app da Tela de Início do iPhone tem cookies próprios (não herda o login do Safari) e o iOS fecha o
  processo a toda hora (cookie de sessão sumia). Ao entrar grava-se o cookie cifrado `ma_remember`
  (30 dias; pessoa + pedaço do digest da senha; httponly, SameSite=Lax, secure em produção). Sem sessão,
  ele a refaz. Sair, trocar a senha, desativar a pessoa ou excluir a conta derrubam. Escrito só ao entrar,
  refazer e sair (validade deslizante no cookie de sessão foi descartada: todo pedido regravaria o cookie e
  um pedido em voo podia desfazer o "Sair").
- Passkey funciona no standalone (WebAuthn, iOS 16+). O botão do Google (pop-up do GIS) pode não voltar ao
  app standalone: a tela de entrar mostra a nota apontando senha/passkey (`pwa.login.standalone_google`).
  O modo redirect do GIS exigiria registrar o endereço no Google Cloud e trocar o CSRF; ficou de fora.
- Navegador mínimo (`allow_browser`): Safari 16.4 (era o 17.2 do `:modern`, que barrava iOS 16.4–17.1) e
  a tela "Navegador antigo demais" nos 3 idiomas (antes, erro 500 por falta do
  `public/406-unsupported-browser.html`).

## O que o app Android faz e o PWA no iPhone não consegue

| App Android | PWA no iPhone | O que já existe no MA |
|---|---|---|
| Presença por localização em segundo plano (`MobileAppPlugin`) | Sem geolocalização nem nada rodando em segundo plano | Rastreador de rede (`NetworkTrackerPlugin`: o celular respondendo na rede da casa por ping ou TCP) e os rastreadores de `People::TRACKERS` que não dependem do app (cômodo/ESPresense, rosto, conectado), com a tolerância para sair (`away_delay_s`) |
| Bateria, carregando e Wi-Fi como pontos | Não há API | Só pelo app Android |
| Aviso com botões, imagem, progresso, grupo | Só título, texto, ícone e toque (abre o link) | O botão vira link para `/notificacoes` (responder lá); Telegram/WhatsApp (`Notifier::Channels::Messenger`) levam botões |
| Push com o app fechado sempre | Chega, mas só com o app na Tela de Início e a permissão dada | — |
| Widget/atalhos do ícone | Sem atalhos do manifesto | Siri/Atalhos chamando o webhook das automações ou a API com chave (`ServiceApiKey`) |
| Login Google pelo Credential Manager | Pop-up do Google pode não voltar | Passkey e senha; aparelho lembrado 30 dias |

## Testes

`spec/requests/pwa_ios_spec.rb` (manifesto, service worker, sem conexão, telas, cookie de lembrar, piso do
Safari, `unread` no payload). Navegador: Playwright WebKit com `devices["iPhone 15"]` (`is_mobile: false`:
o WebKitGTK do Playwright cai no Início com `is_mobile`, também no master) e Chromium Pixel 7; push pelo
`ServiceWorker.deliverPushMessage` do CDP no Chromium (nada vai a celular nenhum).
