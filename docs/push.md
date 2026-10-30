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
| apagar | `clear` + `tag` | marca como lido | fecha a notificação | dado `clear` | — |

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
  O FCM já é um transporte: quando o app F7 existir, ele só monta a
  notificação com o `data` recebido.
- Spec: `spec/services/lote1_spec.rb` registra um canal e um transporte falsos
  por `stub_const` e prova que funcionam sem mudar o núcleo.

## Resposta aos botões

A primeira resposta vale (`responded_at`/`response`) e vira o evento
`notification_action` (`Automations::Triggers.event`): dispara o gatilho
"Resposta de aviso" e retoma a ação "Esperar resposta do aviso" da mesma
execução. Pelo service worker, `POST /push/resposta {token, action_id}` sem
sessão: o token é assinado com a notificação e a pessoa
(`Notification#action_token`, 7 dias), não serve para outra pessoa nem para
outro aviso e só vale uma vez (409 depois). Pelo app, `PATCH
/notificacoes/:id/responder` com a sessão.

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
