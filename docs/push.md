# Avisos, push e PWA (Lote 1)

O aviso (`Notification`) é o registro que todo canal leva. A ação "Avisar"
(e as regras de aviso e de alerta) declara o que quer e cada canal usa o que
suporta.

## O que um aviso pode pedir (`Notifier::FEATURES`)

| Recurso | Na ação `notify` | In-app | Push (Web Push) | Push (FCM, app F7) | Alexa |
|---|---|---|---|---|---|
| texto | `title`, `message` | sim | sim | sim | fala título + corpo |
| botões | `buttons` (até 3 {id, title}) | sim | sim (o Chrome mostra até 2 no Android) | leva no `data` | ignora |
| imagem | `camera` (quadro agora) ou `image_url` | sim | sim (URL assinada, 7 dias) | leva no `data` | ignora |
| link ao tocar | `url` (`/paineis/...` ou `https://`) | botão "Abrir" | abre ao tocar | leva no `data` | ignora |
| tag | `tag` | substitui o anterior não lido | substitui no aparelho | leva | ignora |
| prioridade | `priority` | — | `critical` = fica até tocar, nunca agrupa; `high`/`critical` = urgência alta | leva | ignora |
| validade | `ttl` | — | TTL do Web Push | leva | ignora |
| fixo | `sticky` | — | fica até tocar (`requireInteraction`) | leva | ignora |
| grupo | `group` | — | **não existe na Web**: ignorado | leva | ignora |
| progresso | `progress` (Liquid → 0–100, ex.: `{{ points["robo.progresso"].value }}`) | — | **não existe na Web**: ignorado | barra contínua; com `tag` atualiza no lugar; 100 encerra | ignora |
| apagar | `clear` + `tag` | marca como lido | fecha a notificação | dado `clear` | — |

Botão que comanda (app2): `fechar: Fechar -> garagem.portao pulse` no editor
(ou `{id, title, point, command, value}` no JSON). Ao tocar, o servidor manda
o comando como a pessoa, com a regra de papel x risco da API (origem "botão
do aviso"); sem permissão a resposta vale, mas o comando não sai. Vale para o
app, a PWA e o sino, porque tudo passa por `Notification#respond!`.

Destinatário (`to`): `admins` (padrão, dono e administradores), `user:<id>`
(todos os aparelhos da pessoa) ou `role:<papel>` (quem tem pelo menos o papel
no local; `role:guest` = todos do local). Uma notificação por pessoa.

## Canais e transportes (aberto para extensão)

- **Canal** = plugin em `Notifier::Channels` (`Notifier::CHANNELS`):
  `owns?(canal)`, `choices(site)`, `label(canal)`, `capabilities` e
  `deliver(canal, notificações)` (+ `clear(notificação, tag)` e `default`
  opcionais). Telegram, e-mail, SMS ou WhatsApp entram assim, sem tocar no
  Notifier, na ação "Avisar" nem no editor (as opções vêm de `choices`).
- **Transporte de push** = módulo em `Push::TRANSPORTS` (`Browser`, `Fcm`):
  `configured?`, `capabilities`, `deliver(user, message)` e `clear(user, tag)`.
  `Push::Message#to_h(capabilities)` corta o que o transporte não suporta.
  O FCM leva ao app F7 (Android) uma mensagem **só de dados** (`type:
  notification`, `title`, `body`, `actions` em JSON, `token`, `image`, `tag`,
  `priority`, `group`, `url`, `notification_id`): o app monta a notificação,
  inclusive fechado. iOS recebe a notificação do sistema + os dados. Detalhes
  em `docs/app.md`.
  Ligado no Dell e na VPS (projeto Firebase `minha-automacao-114798`,
  conta `fcm-sender@` só com o papel do FCM); testado no emulador com o app em
  segundo plano e com o processo encerrado, resposta pelo botão registrada.
- Spec: `spec/services/lote1_spec.rb` registra um canal e um transporte falsos
  por `stub_const` e prova que funcionam sem mudar o núcleo.

## Mensageiros: Telegram, WhatsApp e gateway HTTP (Pacote 4)

Canal `messenger:<id da integração>` (`Notifier::Channels::Messenger`):
toda integração cujo plugin responde a `send_message(integração,
notificação)` aparece nos canais do aviso como "<tipo>: <nome>". Mensageiro
novo = plugin de integração com `send_message` (+ `webhook(integração,
request)` se recebe respostas); nada muda no Notifier, na ação "Avisar" nem
no editor. Uma mensagem por aviso (o destino é a conversa da integração).
Falha = integração "Com erro" (os outros canais seguem). Cada um tem
formulário em Integrações, "Enviar teste" no Reconfigurar e as credenciais
cifradas (`integrations.credentials`).

| | Telegram | WhatsApp (API oficial) | Gateway HTTP |
|---|---|---|---|
| Conta | bot da pessoa (token do @BotFather) | app da Meta da pessoa: token, Phone number ID, número que recebe | endereço, método, cabeçalhos e corpo em Liquid |
| Texto + link | sim | sim | `{{ text }}`, `{{ url }}` |
| Imagem do aviso | `sendPhoto` (envio do anexo) | mídia enviada à Meta (`/media`) | `{{ image_url }}` (assinada) ou `{{ image_base64 }}` |
| Botões | teclado embutido | até 3 botões de resposta (título até 20) | — |
| Respostas | leitura no worker (`getUpdates`, padrão) ou webhook | webhook da Meta | — |

- **Telegram**: "Achar meu chat" lê o `getUpdates` (a pessoa manda uma
  mensagem ao bot antes) e lista as conversas. Respostas: sem endereço
  público, `Integrations::TelegramPlugin.listen` no worker faz espera longa
  (20 s) e confirma pelo `offset` (`TELEGRAM_LISTENER=off` desliga); com
  "Receber por webhook", `setWebhook` para `https://APP_HOST/mensageiros/:id`
  com `secret_token` próprio (cabeçalho conferido). Só vale o botão tocado na
  conversa configurada. O token vai no caminho da API: nunca aparece em erro.
- **WhatsApp**: a Meta só aceita mensagem livre até 24 h depois da última
  mensagem da pessoa para o número. Com "Modelo" (aprovado na Meta, texto com
  o parâmetro 1) o aviso sai sempre, mas sem foto nem botões. Respostas: no app
  da Meta, webhook `https://APP_HOST/mensageiros/:id`, token de verificação
  mostrado no Reconfigurar, campo `messages`; o POST só vale com
  `X-Hub-Signature-256` do segredo do app e do número configurado.
- **Gateway HTTP**: Evolution API, CallMeBot, ntfy, Gotify ou qualquer API,
  sem caso especial. Variáveis `title`, `message`, `text`, `url`,
  `image_url`, `image_base64`, `buttons`; filtro `json` (`{{ text | json }}`)
  e `url_encode`. Passa pelo `SafeHttp` (servidor na rede de casa: libere o
  IP em Configurações → Sistema).
- Botão do mensageiro → `Notifier::Channels::Messenger.respond` → mesma
  `Notification#respond!` do push (uma vez; gatilho "Resposta de aviso").
  Quem responde: quem ligou a integração (`settings.user_id`), senão a dona
  do aviso, senão o dono da instalação.
- `GET|POST /mensageiros/:id` (`MessengerWebhooksController`): sem sessão; o
  plugin valida tudo, sem plugin com `webhook` = 404.
- Spec: `spec/services/pacote4_messengers_spec.rb` (WebMock em tudo e um
  mensageiro falso registrado por `stub_const`).

## ntfy (apps, 11/2026)

`Integrations::NtfyPlugin` (servidor do app `ntfy` do catálogo ou o ntfy.sh):
endereço, tópico (`[\w-]{1,64}`), token (cifrado, Bearer) e prioridade.
Publica JSON na raiz do servidor pelo `SafeHttp` (`topic`, `title`,
`message`, `priority`, `click`, `attach` só com https). Botões (até 3) viram
ações `http` do ntfy para `https://APP_HOST/mensageiros/:id` com o cabeçalho
`X-MA-Token` (segredo próprio da integração, gerado no salvar) e a
referência no corpo; sem `APP_HOST`, sem botões. Spec só com WebMock.

## Resposta aos botões

A primeira resposta vale (`responded_at`/`response`) e vira o evento
`notification_action` (`Automations::Triggers.event`): dispara o gatilho
"Resposta de aviso" e retoma a ação "Esperar resposta do aviso" da mesma
execução. Pelo service worker, `POST /push/resposta {token, action_id}` sem
sessão: o token é assinado com a notificação e a pessoa
(`Notification#action_token`, 7 dias), não serve para outra pessoa nem para
outro aviso e só vale uma vez (409 depois). O app usa o mesmo `POST
/push/resposta` com o `token` que veio no FCM (botão tocado com o app
fechado, sem sessão) e, na lista de avisos, `POST
/api/v1/notifications/:id/respond {action_id}`. Na web, `PATCH
/notificacoes/:id/responder`.

## Imagem

`camera` captura o quadro do go2rtc no momento do aviso
(`Drivers::Go2rtc.snapshot`) e guarda no Active Storage, anexado à
notificação. O push leva `/push/imagem?t=<id assinado>`, que vence em 7 dias
(`Notification::IMAGE_TTL`); o go2rtc nunca fica exposto. O
`ReadingsMaintenanceJob` apaga os quadros vencidos. Câmera fora do ar: o aviso
sai sem imagem e o trace diz.

## PWA e Web Push

- Manifesto `/manifest.json`, service worker `/service-worker.js`
  (`app/views/pwa/`), ícones em `public/` (`icon-192`, `icon-512`,
  `apple-touch-icon`, `badge-96`).
- Chaves VAPID: `bin/vapid-keys [.env]` gera o par P-256 e grava só se não
  existir (a privada nunca aparece). No Dell, o `bin/deploy-local` roda isso
  no servidor. Na VPS: `PREFIX=MINHA_AUTOMACAO_ bin/vapid-keys
  /opt/minha-automacao/.env` (o compose passa `VAPID_PUBLIC_KEY` e
  `VAPID_PRIVATE_KEY`). Sem as chaves, o transporte Web Push fica desligado.
  Trocar as chaves invalida as inscrições.
- **Exige https.** No Dell vale pelo acesso externo
  (`https://casa-automacao.minhasuite.com`); pelo `http://192.168.68.199` o
  navegador não registra o service worker e a tela avisa.
- **Android (Chrome):** instale a PWA (menu → "Instalar app") e inscreva em
  Configurações → Meus aparelhos. Funciona também no Chrome sem instalar.
- **iPhone:** só iOS 16.4+ e só com a PWA na tela inicial (Compartilhar →
  Adicionar à Tela de Início), aberta pelo ícone.
- "Apagar aviso" pelo Web Push fecha a notificação; alguns navegadores podem
  mostrar um aviso genérico quando um push chega sem notificação nova.
