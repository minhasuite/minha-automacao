# Integrações e dispositivos (F8c)

Como no HA: conecta-se uma **conta** e o sistema varre e lista os aparelhos
dela sozinho. Tudo fica dentro do local: `/locais/:id/integracoes` (cards e
catálogo) e `/locais/:id/dispositivos` (lista de todos os aparelhos).

## Plugins (aberto para extensão)

Cada tipo é um plugin em `app/services/integrations/<nome>_plugin.rb`,
subclasse de `Integrations::Plugin`, registrado em `Integrations::PLUGINS`
(a ordem é a do catálogo). Nada fora do plugin pergunta "que tipo é":
controller e telas só seguem o que ele devolve.

| Método | Para quê |
| --- | --- |
| `describe key:, title:, icon:, description:, driver:` | catálogo e card (`driver` = `integrations.driver`; `nil` = só importa, sem card) |
| `setup(site, form)` | assistente "Adicionar" → `Outcome` |
| `login(integration, form)` | Reconfigurar (mesmo formulário) → `Outcome` |
| `connect_locals(integration, params)` | variáveis da tela de login (QR) |
| `logged_in?(integration)` | a tela pergunta a cada 3 s; `true` = logou e a varredura já está na fila |
| `inventory(integration)` | lista da conta (formato abaixo) |
| `device_secret(integration, entry)` | segredo gravado no aparelho adotado (padrão: `entry["secret"]`) |
| `custom_sync?` / `sync!` | varredura própria (Alexa) |
| `reconfigurable?` | mostra "Reconfigurar" |

`Outcome.to`: `:found` (encontrados), `:connect` (passo de login), `:index`,
`:devices` ou `:form` (formulário de novo com `alert`).

Telas do plugin: `web/integrations/forms/_<key>.html.erb` (campos do
assistente e do Reconfigurar) e, se precisar, `web/integrations/connect/_<key>`
(QR, captcha, 2FA). **Integração nova = classe + linha em `PLUGINS` +
partial do formulário.**

Mapas de categoria/modelo → pontos são dados: `config/device_maps/tuya.yml`
(códigos de dp) e `config/device_maps/miot.yml` (propriedades MIoT).

## Inventário, varredura e adoção (`Integrations`)

Entrada: `{id, kind (driver do aparelho), name, manufacturer, model, category,
room, online, sub, secret, address, poll_s, match, points: [atributos de
ponto]}`, guardada cifrada em `integrations.inventory`.

- `sync!` (botão "Sincronizar agora" → `SyncIntegrationJob`; periódica pelo
  `Polling`, `poll_s` padrão **6 h** nas contas novas): status `syncing` →
  `ok`/`error`.
- Aparelho já cadastrado casa por `driver + external_id` (Tuya: device_id;
  Xiaomi: did; MQTT: ieee) ou, com `"match" => "host"`, pelo IP (DVR que veio
  do `go2rtc:importar`). **Nunca duplica**: liga à integração, troca a
  chave local/token se mudou e o IP (Xiaomi).
- Sumiu da conta: `devices.removed_at` ("Removido da conta"); nada é apagado.
  Voltou: limpa.
- Novo na conta (a partir da 2ª varredura): notificação `integracao`
  "Novo dispositivo encontrado" e o badge "N novo(s) para adicionar" no card.
- `adopt!(integration, {id => área})`: área existente, `new:<cômodo>` (cria) ou
  vazia; a sugestão vem do cômodo da nuvem. Cria aparelho e pontos (chave do
  ponto única no local).

## Tipos

- **Tuya / Smart Life** (`Tuya::Cloud`): o mesmo caminho da integração
  oficial `tuya` do HA (tuya-device-sharing-sdk 0.2.x, client id do HA):
  código de usuário → `POST apigw.iotbing.com/v1.0/m/life/home-assistant/qrcode/tokens`
  → QR `tuyaSmart--qrLogin?token=…` → poll em `.../tokens/:token` → tokens.
  Pedidos assinados (HMAC) e cifrados (AES-128-GCM); o access token se renova
  sozinho. Por aparelho: `devices/:id/status` (mapa dpId → código/tipo),
  `specifications` (o que é gravável) e o cômodo. Interruptor, lâmpada e
  medição passam pela mesma tradução da importação do LocalTuya
  (`Tuya::Import.specs_for`). A nuvem **não dá o IP da rede local** nem a
  versão do protocolo: nascem `3.3` sem IP; preencha o IP na edição e use
  **Reconectar** (tenta 3.3/3.4/3.5/3.1 e grava a que respondeu). Os 12
  aparelhos importados do LocalTuya já têm IP e versão. Sub-aparelho de
  gateway Zigbee aparece mas não é adotável (controle local exige o gateway).
- **Xiaomi** (`Miio::Cloud`): login próprio (nunca o OAuth do `xiaomi_home`
  do HA). Senha (MD5 + `_sign`), captcha (imagem na tela, texto de volta) ou
  QR do Mi Home (`longPolling/loginUrl`), que é o caminho quando a Xiaomi
  pede 2FA. API do app cifrada em RC4 (`gethome`, `get_device_cnt`,
  `home_device_list`), servidor escolhido ou todos. Pontos: robô pelo
  `Miio::Vacuum`; o resto pela especificação pública do miot-spec.org.
- **Alexa**: cookies da sessão (`Alexa::Import`), varredura = lista de Echo.
- **Câmeras / DVR** (`Isapi`): ISAPI Hikvision com Digest
  (`/ISAPI/System/deviceInfo`, `/ISAPI/Streaming/channels`), um aparelho
  `go2rtc` com um ponto `stream` por canal no substream (x02). O
  `Go2rtcSyncJob` põe as câmeras no go2rtc. ONVIF fica para depois.
- **MQTT / Zigbee2MQTT**: sem conta; o card liga os aparelhos `mqtt` do local
  (a descoberta continua no `Mqtt::Z2m`).
- **Google Agenda / ICS** (F9, `CalendarPlugin`, `Calendars`): modo **link
  iCal** (o "endereço secreto no formato iCal" do Google ou qualquer .ics;
  links cifrados nas credenciais, baixados pelo `SafeHttp`) ou modo **conta
  Google** (OAuth só leitura, `Calendars::Google`; aparece só com
  `GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET`; URI de retorno a cadastrar no
  Google Cloud: `https://<host>/integracoes/oauth/retorno`). Um ponto
  `calendar` por agenda no dispositivo virtual `calendar:<integração>`: eventos
  de ontem a +31 dias em `address.events`, valor = evento de agora ou o
  próximo (`{summary, start, end, all_day, location, now}`), refeito a cada
  minuto por `Integrations.tick` (RunSchedulesJob). Leitura a cada 15 min
  (`poll_s`). Gatilho `calendar` e condição `calendar` da DSL. O retorno OAuth
  (`/integracoes/oauth/retorno`, `state` assinado com o id da integração) é
  genérico: plugin novo com OAuth implementa `oauth_callback`.
- **Importar do Home Assistant**: arquivo `core.config_entries`; entram as
  entradas do LocalTuya (`Tuya::Import`, idempotente). O resto do arquivo é
  descartado.

Card da integração (F8d): uma ação principal, "Ver dispositivos", e o menu
"⋯" (técnico+) com Sincronizar agora, Reconfigurar, Intervalo e Remover.

**Novo** só vale para o aparelho adotado de uma varredura (`devices.discovered_at`,
gravado no `adopt!`) que ainda não teve nenhum contato (`last_seen_at` nulo),
por até 7 dias. Os demais (inclusive DVR casado por IP e virtuais) mostram
Online / Offline / Com erro.

## Lista de dispositivos e página do dispositivo

`/locais/:id/dispositivos`: tabela (nome, fabricante/modelo, área,
integração, pontos, situação), filtros (integração, área, situação: Online
/ Offline / Com erro (pelo último contato) / Novo / Removido da conta), busca e
paginação (50). Ações em massa (técnico+): mover de área, ligar/desligar a
leitura periódica (30 min / 0) e remover.

Página do dispositivo: diagnóstico (situação, último contato, IP, versão,
integração, leitura, último erro de leitura em `devices.last_error`, falhas
recentes de qualidade), **Reconectar** (`PollDeviceJob` com `reconnect`),
**Atualizar agora** e **Onde é usado** (painéis, automações, cenas,
espelhamentos, avisos, alertas e agendas que citam os pontos, por id ou
chave).

## Conectar (passo a passo do usuário)

**Smart Life:** no app, Eu → engrenagem → Conta e segurança → copiar o
**Código de usuário**. No local: Integrações → Tuya / Smart Life → colar →
Continuar → escanear o QR pelo app (botão de leitura no Início) → Autorizar.
A tela vai sozinha para "Dispositivos encontrados"; marque e "Adicionar".

**Xiaomi:** Integrações → Xiaomi → e-mail/telefone/ID, senha e servidor
(ou "Procurar em todas") → Continuar. Se aparecer a imagem, digite o texto e
a senha de novo. Se pedir duas etapas, use "Entrar com o QR code" e escaneie
pelo Mi Home.
