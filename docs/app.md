# App Flutter (F7)

O app `minha-automacao-app` (mesmo workspace, `com.minhasuite.minhaautomacao`)
é nativo, sem WebView, e **genérico**: tudo o que mostra vem do servidor. Ele
não conhece nenhuma casa, aparelho ou automação; desenha o painel resolvido
(`docs/dashboards.md`) e manda comandos pela mesma API da web.

## O que o servidor oferece ao app

| Para quê | Onde |
|---|---|
| Login, refresh, sessão | `POST /api/v1/auth/{login,refresh}`, `DELETE /auth/logout`, `GET /me` |
| Locais, áreas, aparelhos | `GET /sites` (com `my_role` e `points_stream`), `/sites/:id/areas`, `/sites/:id/devices` |
| Pontos de um aparelho como o app desenha | `GET /devices/:id/points?view=app` (texto, `commands`, `actions`, `can_command` pelo papel) |
| Painel | `GET /sites/:id/dashboards`, `GET /dashboards/:id` (resolvido, `points` com `can_command`) |
| Comando | `POST /points/:id/commands` (papel x risco no servidor; o app pede confirmação quando `risk` ≠ normal ou `confirm`) |
| Histórico | `GET /points/:id/history` |
| Câmera | `GET /points/:id/snapshot` (JPEG pelo Rails; o go2rtc nunca fica exposto) |
| Cenas e automações | `GET /sites/:id/scenes`, `POST /scenes/:id/activate`, `GET /sites/:id/automations`, `PATCH /automations/:id {enabled}`, `POST /automations/:id/run` (`confirm_critical`) |
| Alertas e avisos | `GET /alerts`, `POST /alerts/:id/ack`, `GET /notifications` (com `actions`, `url`, `image_url`), `POST /notifications/:id/respond {action_id}` |
| Push | `POST/DELETE /device_tokens` (FCM) |
| Sensores do celular | `POST /sites/:id/mobile_devices`, `POST /mobile_devices/:id/sensors`, `DELETE /mobile_devices/:id` |

## Tempo real

O mesmo Action Cable da web: `wss://<servidor>/cable?access_token=<access>`
com o cabeçalho `Origin` igual ao endereço do servidor
(`ApplicationCable::Connection#app_user`). O app assina o `PointsChannel` com
`signed_stream_name` = `Site#points_stream` e recebe
`<turbo-stream action="point_changed" target="<id>">`; se o ponto está nas
dependências do painel aberto, relê `GET /dashboards/:id`. O access vence em
30 min: a conexão aberta segue; a reconexão usa o token renovado.

## Push com botões (FCM)

`Push::Fcm` manda ao Android uma mensagem **só de dados** (`type:
notification`, `title`, `body`, `actions` em JSON, `token`, `image`, `tag`,
`priority`, `group`, `requireInteraction`, `notification_id`). O app monta a
notificação (canal `avisos` ou `criticos`) inclusive fechado, e o botão
responde em `POST /push/resposta {token, action_id}` sem sessão (o token é da
pessoa e do aviso, vale uma vez). `type: clear` apaga pela tag. iOS recebe a
notificação do sistema + os dados.

**Ligar** (passo do dono, uma vez): criar o projeto Firebase do app
(skill `android-suite`/`lancar-app-play`), baixar o `google-services.json`
para `minha-automacao-app/android/app/` (e o secret
`GOOGLE_SERVICES_JSON_BASE64` no CI) e pôr no servidor `FCM_CREDENTIALS_JSON`
(conta de serviço com "Firebase Cloud Messaging API") e `FCM_PROJECT_ID` no
`.env` (Dell: `/opt/minha-automacao/.env`; VPS: `MINHA_AUTOMACAO_FCM_*`).
Sem isso o app funciona inteiro, só sem push.

## App do celular (G17)

Integração `mobile_app` (`Integrations::MobileAppPlugin`, no catálogo como
"App do celular"): cada celular com o app vira um aparelho **virtual** do
local, da pessoa que entrou (`external_id` = `mobile_app:<user>:<install_id>`,
`address.user_id`). Sensores = `SENSORS` (campo → ponto):

| Campo | Ponto | Capacidade |
|---|---|---|
| `battery` | Bateria (%) | `measure`, `device_class: battery` |
| `charging` | Carregando | `onoff` só leitura, `battery_charging` |
| `wifi` | Wi-Fi (SSID; vazio = fora do Wi-Fi) | `text` |
| `location` | Presença (`Em casa` / `Fora`) + atributos `latitude`, `longitude`, `accuracy`, `distance_m` | `enum` |

Presença: distância até o local (latitude/longitude do cadastro) menos a
imprecisão do GPS ≤ raio (`settings.home_radius_m` da integração, padrão
150 m, ajustável em Integrações → App do celular). Sem coordenadas no local,
não há ponto de presença. Sensor novo = entrada em `SENSORS` + o app mandar o
campo. O app manda as leituras ao abrir, ao voltar para ele e a cada 15 min
com ele aberto (leitura em segundo plano fica para a próxima rodada).

## Testar

- Servidor: `spec/requests/f7_app_spec.rb` (+ `points_channel_spec`,
  `lote1_spec` para o FCM).
- App: `flutter test` (smoke de todas as telas com respostas reais em
  `test/fixtures/api.json`, regravadas por `test/fixtures/capturar.rb`).
- Contra o Dell: usuário de teste próprio (criar e apagar no fim); nunca a
  conta do dono, nunca comandar aparelho real além do combinado.
