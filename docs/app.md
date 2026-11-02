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
| Pontos do local (widgets, atalhos e controles do Android) | `GET /sites/:id/points?view=app[&commandable=1]`, `GET /points/:id?view=app` |
| Editor do painel no app (técnico/dono) | `GET /dashboards/:id/definition` (rascunho + `meta.catalog` dos plugins de widget), `PUT /dashboards/:id {definition, publish}` |
| Descoberta na rede de casa | mDNS `_minhaautomacao._tcp` (serviço `mdns` do compose local, `bin/mdns-announce`) |

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

**Ligado** (31/10/2026): projeto Google Cloud/Firebase `minha-automacao-114798`
(um projeto por app, convenção do `minha-infra`, skill `android-suite`), app
Android com os SHA-1/SHA-256 da chave de upload. O `google-services.json` fica
em `vault/android/minha-automacao-google-services.json`, em
`android/app/google-services.json` (gitignored) para o build local e no secret
`GOOGLE_SERVICES_JSON_BASE64` do CI. O servidor envia com a conta
`fcm-sender@minha-automacao-114798.iam.gserviceaccount.com` (só o papel
`roles/firebasecloudmessaging.admin`; chave em
`vault/firebase/minha-automacao-adminsdk.json`): no Dell `FCM_CREDENTIALS_JSON`
e `FCM_PROJECT_ID` em `/opt/minha-automacao/.env`; na VPS
`MINHA_AUTOMACAO_FCM_CREDENTIALS_JSON`/`MINHA_AUTOMACAO_FCM_PROJECT_ID` no
`.env` de `/opt/minha-automacao` (o compose repassa ao web e ao worker). Valor
de uma linha, entre aspas simples, gravado por script Python (nunca `awk -v`).
Trocar a chave: nova chave da conta, regravar as duas `.env`, `docker compose
up -d web worker`. Sem credencial o app funciona inteiro, só sem push.

O botão da notificação depende do receiver
`com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver` no
`AndroidManifest.xml`; sem ele o toque em Sim/Não não faz nada com o app em
segundo plano ou fechado.

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

## Pacote 3 no app

- Sensores do celular: intervalo escolhido (5, 15, 30 ou 60 min com o app
  aberto) e economia de bateria (localização pela rede; nenhuma com bateria
  baixa fora da tomada). A resposta de `POST /mobile_devices/:id/sensors` traz
  `zone` (zona onde a localização caiu), nunca a coordenada; a tela mostra
  "Zona agora". Pessoas e zonas em `docs/presenca.md`.
- Widgets `people` e `alarm` (teclado; o código vai no comando e não fica no
  app). Painel de alarme em `docs/alarme.md`.
- Microfone no Início: grava (AAC) e manda para `POST /sites/:id/assist`
  (multipart `audio`, ou `text`), mostra o que entendeu e a resposta e toca a
  fala (`audio_url`). Ver `docs/assistente.md`.

## App 0.2 (app2)

- Primeiro uso: o login procura `_minhaautomacao._tcp` na rede (mDNS) e
  oferece o servidor achado; o anúncio é o serviço `mdns` do
  `docker-compose.local.yml` (rede do host, só UDP 5353). Biometria opcional.
- Android: widget de ponto/cena na tela inicial, 3 atalhos no painel rápido e
  os controles do menu de energia. Tudo pela API com o token do app (papel x
  risco no servidor; ponto com risco ou `confirm` abre o app para confirmar,
  e nos controles o Android pede a confirmação).
- Avisos: botão que comanda um ponto e barra de progresso (`docs/push.md`).
- Editor do painel no app: reordena seções e widgets, tira e põe widgets do
  catálogo e salva rascunho ou publica.
- Spec: `spec/requests/app2_spec.rb`.

## App 0.3 (app3)

- Telas nativas de Diário (`/sites/:id/logbook`), Histórico
  (`/sites/:id/history`) e Mapa (`/sites/:id/map`), as mesmas da web.
- Painel: widgets `energy_flow`, `energy_breakdown`, `energy_compare`,
  `floorplan` e `map` desenhados no app (cada um por
  `WidgetRegistry.register`). Tema: cada visão do `GET /dashboards/:id` traz
  `theme_now` ({key, label, accent, accent2, glass, night, image, blur}), o
  tema que vale agora (painel + visão, o de noite das 18h às 6h no fuso do
  local); o app pinta pelas cores que vierem, então tema novo no servidor
  (`Dashboards::Themes::PLUGINS`) já aparece sem versão nova do app.
- Alertas de detecção: `GET /sites/:id/detections` (lista com quadro, filtro
  por tipo e câmera, cursor `before`). O quadro de uma detecção antiga sai de
  `/points/:id/snapshot?event=<id>` quando o plugin guarda por evento
  (`Integrations::Plugin.event_snapshots?`, hoje o Frigate); nos outros, só a
  detecção de agora tem quadro. O app avisa (notificação local com o quadro)
  quando uma detecção chega pelo tempo real com o app aberto ou em segundo
  plano; com o app fechado, o aviso vem da automação "Câmera detectou" +
  "Avisar" com quadro (push).
- Spec: `spec/requests/app3_spec.rb` (plugin de câmera falso e tema falso por
  `stub_const`).
