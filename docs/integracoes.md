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
(códigos de dp) e `config/device_maps/miot.yml` (propriedades MIoT). No
Tuya, além de nome, unidade e capacidade, o código leva `risk` (sirene =
crítico) e as chaves de endereço `decode`/`field`/`match`/`hold_s`/
`push_only`: valor empacotado (ex.: `initiative_message` da câmera, base64
de JSON com `cmd: ipc_motion`) vira ponto por `Points::Decode`
(decodificador novo = uma linha em `DECODERS`), volta a falso sozinho
depois de `hold_s` (`PointHoldJob`) e, com `push_only`, só conta quando o
aparelho empurra (o estado completo repete a última mensagem). Lote 6:
`patterns` (família numerada, ex.: `switch_modeN` → "Botão N"), `gateways`
(categorias de hub), `read_only` (dp gravável que não vira comando, ex.:
motor da fechadura), `state_class`, decodificador `value` com `unmatched`
(enum → sim/não: `pir`/`none` → movimento, `master_state` alarm → problema)
e capacidade `event` (botão, campainha, destravou por digital): o ponto de
evento dispara gatilho a cada aviso, mesmo repetido (`Point#report!` e
`Triggers.changed_into?` olham a capacidade, não o aparelho).

## Inventário, varredura e adoção (`Integrations`)

Entrada: `{id, kind (driver do aparelho), match_drivers, name, manufacturer,
model, category, room, online, sub, secret, address, poll_s, match, state,
points: [atributos de ponto]}`, guardada cifrada em `integrations.inventory`.
`match_drivers` = drivers que são o mesmo aparelho (Tuya: `tuya_cloud` e
`tuya_local`); `address.via` = id do hub do sub-dispositivo. Depois da
varredura e da adoção o plugin grava o estado atual (`Plugin.refresh`).

- `sync!` (botão "Sincronizar agora" → `SyncIntegrationJob`; periódica pelo
  `Polling`, `poll_s` padrão **6 h** nas contas novas): status `syncing` →
  `ok`/`error`.
- Aparelho já cadastrado casa por `driver + external_id` (com qualquer driver
  de `match_drivers`; Tuya: device_id;
  Xiaomi: did; MQTT: ieee) ou, com `"match" => "host"`, pelo IP (DVR que veio
  do `go2rtc:importar`). **Nunca duplica**: liga à integração, troca a
  chave local/token se mudou e o IP (Xiaomi).
- Sumiu da conta: `devices.removed_at` ("Removido da conta"); nada é apagado.
  Voltou: limpa.
- Novo na conta (a partir da 2ª varredura): notificação `integracao`
  "Novo dispositivo encontrado" e o badge "N novo(s) para adicionar" no card.
- Lote 8: ponto que o mapa de dados passou a trazer (cor da lâmpada, evento
  do robô) entra no aparelho já cadastrado na próxima varredura
  (`Integrations.add_points`; casa pelo endereço `dps` ou `siid/piid/eiid`).
  O que já existe não muda (nem o endereço: mapa novo em ponto antigo pede
  ajuste de dado).
- `adopt!(integration, {id => área})`: área existente, `new:<cômodo>` (cria) ou
  vazia; a sugestão vem do cômodo da nuvem. Cria aparelho e pontos (chave do
  ponto única no local).

## Tipos

- **Tuya / Smart Life** (`Tuya::Cloud`, Lote 6): igual à integração
  oficial `tuya` do HA (tuya-device-sharing-sdk 0.2.x, client id do HA):
  código de usuário → `POST apigw.iotbing.com/v1.0/m/life/home-assistant/qrcode/tokens`
  → QR `tuyaSmart--qrLogin?token=…` → poll em `.../tokens/:token` → tokens.
  Pedidos assinados (HMAC sobre os cabeçalhos + query cifrada + corpo
  cifrado) e cifrados (AES-128-GCM, `{"encdata": …}`); o access token se
  renova sozinho. Lista: `users/homes` → `ha/home/devices` (com `status`
  = estado atual, `sub`, `local_key`); por aparelho `devices/:id/status`
  (mapa dpId → código/tipo), `specifications` (o que é gravável) e o cômodo
  (controle IR virtual responde texto vazio: vira `{}`).
  - **Aparelho da nuvem = driver `tuya_cloud`**: comando por código do dp
    (`POST /v1.1/m/thing/:id/commands` `{"commands": [{code, value}]}`, valor
    bruto pela escala do ponto); o ponto leva `address.code`. Até o eco do
    MQTT chegar, o ponto fica com o valor pedido.
  - **Sub-dispositivos do hub** (Zigbee, IR) entram e são adotáveis, com
    `address.via` = hub. A API não diz o pai: filho com a mesma chave local de
    um hub (categoria em `gateways`) é dele; senão, o único hub sem filho na
    própria chave (o hub Zigbee tem chave própria e os filhos dividem outra).
  - **Tempo real** (`Tuya::CloudListener`, worker, `TUYA_CLOUD_LISTENER=off`
    desliga): `POST /v1.0/m/life/ha/access/config` (linkId próprio) → MQTT
    TLS na `url` com clientId/usuário/senha → assina `topic.devId.sub` de cada
    aparelho da conta que está no local. `protocol` 4 = status (`dpId` ou
    `code` → ponto, conta `push_only`); 20 = `online`/`offline`. Ao conectar
    lê o estado de todos (2 pedidos); a credencial vence (`expireTime`, até
    2 h) e reconecta; caiu = aparelhos `tuya_cloud` indisponíveis e espera
    crescente até 60 s. Sem aparelho adotado não conecta. Reserva: a
    varredura da conta (6 h) regrava o estado; não há leitura por aparelho
    (`poll_s` 0).
  - **Convivência com o LocalTuya**: o mesmo device_id já no local como
    `tuya_local` (importado do HA) não duplica: a varredura liga à conta,
    atualiza a chave, grava o `code` em cada ponto e o estado da nuvem; o
    comando continua **local** (sem IP no aparelho, vai pela nuvem).
  - **Fechadura** (`videolock`/`jtmspro`): só estado, bateria e eventos
    (campainha, alarme, destravou por digital/senha/cartão…). Destravar pela
    nuvem não existe na API de compartilhamento (o HA também não oferece); o
    motor é `read_only` e de risco crítico. **Controle IR** (`wnykq`, TV e AR
    virtuais): entram sem pontos, como no HA (a API de compartilhamento não
    manda tecla IR). **Câmera** (`sp`): ajustes, sirene crítica e movimento;
    o vídeo continua pelo go2rtc (RTSP/ONVIF).
  - **Conectar no MA não derruba o HA**: cada login por QR gera um par de
    tokens próprio (terminal próprio) e o MQTT usa linkId próprio; nada
    renova ou revoga o token do HA. Conferido em 30/10/2026: depois do login no
    MA a integração `tuya` do HA seguiu sem erro. Risco residual: a Tuya pode
    limitar o número de sessões por conta (não visto).
- **Xiaomi** (`Miio::Cloud`): login próprio (nunca o OAuth do `xiaomi_home`
  do HA). Senha (MD5 + `_sign`), captcha (imagem na tela, texto de volta) ou
  QR do Mi Home (`longPolling/loginUrl`), que é o caminho quando a Xiaomi
  pede 2FA. O `lp` do QR vale **uma** requisição (largar por timeout e
  repetir dá 403): o `XiaomiQrLoginJob` segura uma só, numa thread do
  worker, até o QR vencer (~5 min); a tela só lê o estado e mostra
  "QR expirou, gere outro." quando vence. API do app cifrada em RC4 (`gethome`, `get_device_cnt`,
  `home_device_list`), servidor escolhido ou todos. Pontos: robô pelo
  `Miio::Vacuum`; o resto pela especificação pública do miot-spec.org.
- **Alexa** (Lote 3, `Alexa::Auth`): sessão própria pelo login da Amazon
  no navegador da pessoa (o mesmo OAuth do app Alexa que o `alexa_media`
  usa: PKCE, `/auth/register`, cookies por `/ap/exchangetoken/cookies`). A
  senha e o 2FA ficam na página da Amazon; aqui só chegam o código de uso
  único (no endereço final, colado na tela) e, depois, o refresh token e os
  cookies, cifrados. Recusa (401/403) renova sozinha uma vez e repete; se a
  renovação falhar, o card fica "Com erro" e pede "Reconfigurar". Colar
  cookies (`Alexa::Import`) continua como modo avançado, sem renovação.
  Varredura = lista de Echo; cada Echo é um ponto `speaker` (`announce`,
  `speak`, `routine`).
- **Câmera RTSP / ONVIF** (Lote 3, `CameraPlugin`, `Onvif`): uma câmera
  por integração. RTSP: cola o endereço; usuário e senha saem da URL (a
  senha só nas credenciais cifradas e no aparelho). ONVIF: IP, porta e
  conta; lê fabricante, modelo, perfis e o RTSP de cada perfil e, se a
  câmera tem eventos, cria o ponto `motion` (PullPoint, `Onvif::Listener`).
  Vira aparelho `go2rtc` como o do DVR (`docs/cameras.md`).
- **Câmera Tapo (TP-Link)** (`TapoPlugin`, `Tapo`): a câmera ONVIF acima já
  na porta 2020 com a conta da câmera, recursos por modelo
  (`config/device_maps/tapo.yml`), falar pela fonte `tapo://` do go2rtc e,
  opcional, privacidade/LED/detecção/sirene pela API local
  (`Tapo::Client`; `docs/cameras.md`).
- **Câmeras / DVR** (`Isapi`): ISAPI Hikvision com Digest
  (`/ISAPI/System/deviceInfo`, `/ISAPI/Streaming/channels`), um aparelho
  `go2rtc` com um ponto `stream` por canal no substream (x02). O
  `Go2rtcSyncJob` põe as câmeras no go2rtc (sem arquivo de config, PUT e
  DELETE respondem 400 e valem; stream que falha vai para o log e o ponto
  fica `unavailable`, sem parar os outros). Câmera avulsa de qualquer marca: "Câmera RTSP / ONVIF" abaixo.
- **MQTT / Zigbee2MQTT**: sem conta; o card liga os aparelhos `mqtt` do local
  (a descoberta continua no `Mqtt::Z2m`). Pareamento, nome e rede do Zigbee:
  seção "Zigbee" abaixo.
- **Google Agenda / ICS** (F9, `CalendarPlugin`, `Calendars`): modo **link
  iCal** (o "endereço secreto no formato iCal" do Google ou qualquer .ics;
  links cifrados nas credenciais, baixados pelo `SafeHttp`) ou modo **conta
  Google** (OAuth só leitura, `Calendars::Google`; aparece só com
  `GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET`; URI de retorno a cadastrar no
  Google Cloud: `https://<host>/integracoes/oauth/retorno`). Agenda
  compartilhada só como "livre/ocupado" entra pelo `POST /freeBusy`, com os
  horários como eventos `Ocupado` (`busy: true`, sem título); evento de tipo
  diferente do comum guarda `type` (`birthday`: os aniversários moram na
  agenda principal desde 2024). Um ponto
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

### Clima (Lote 4, `WeatherPlugin`)

Previsão do tempo de um provedor em `Weather::PROVIDERS` (padrão Open-Meteo,
grátis e sem chave). A localização é a latitude e longitude do local
(cadastro do local); dá para informar outra só nesta integração (campos
vazios = a do local). Vira o aparelho virtual "Clima" com o ponto `weather`
(valor = condição com os nomes do HA: `sunny`, `partlycloudy`, `rainy`…;
agora, previsão por dia e por hora em `address`) e um `measure` por medida
que o provedor informa (temperatura, sensação, umidade, vento, chance de
chuva hoje). Lê a cada 30 min. **Provedor novo** = classe em
`app/services/weather/providers/` (`describe key:, label:, needs_key:` e
`fetch(lat:, lon:, zone:, api_key:)` no formato comum de `Weather`) + nome em
`PROVIDERS`; chave do provedor fica cifrada na integração.

### Sistema (Lote 4, `SystemPlugin`)

O próprio servidor como pontos do aparelho virtual "Sistema": disco usado
(%) e livre (GB), último backup e "Backup atrasado" (mais de 26 h; lê a pasta
`BACKUP_DIR`, padrão `/backups`, montada só leitura no servidor da casa),
integrações com erro (número e nomes), automações ligadas, execuções e falhas
em 24 h, execuções em andamento, pontos sem sinal, a versão do Minha Automação
(tag da imagem e commit) e o sistema do servidor (o kernel, `Linux 6.12…`: o
`installed_version` dos tiles "Core" e "Sistema" do HA). Lê a cada 5 min. Medida
nova = uma entrada em `SystemPlugin::METRICS`; medida sem leitura no servidor
não cria ponto.

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

## Substituir aparelho (`Devices::Replace`)

Troca o aparelho (ou o caminho até ele) sem refazer painéis, automações,
cenas, ligações, avisos, alertas, helpers, de-para e histórico. Serve para
qualquer driver; o caso que motivou foi o hub Zigbee da Tuya (`tuya_cloud`
com `address.via`) trocado por um coordenador próprio com o Zigbee2MQTT: o
sensor pareado de novo entra pelo `Mqtt::Z2m.discover!` como aparelho **novo**
(`mqtt`, `external_id` = ieee).

**Como:** página do aparelho antigo → **Substituir por…** (técnico+) →
escolhe o aparelho novo do mesmo local → mapeamento ponto antigo → ponto
novo, já sugerido e editável (caixa **Inverter** nos pontos verdadeiro/falso)
→ **Ver prévia** (o que muda, quantas referências continuam certas, ponto
novo que já era usado em algo, pontos sem par, destino do aparelho antigo) →
**Substituir**. Na API: `GET /api/v1/devices/:id/replace?new_device_id=`
(aparelhos possíveis e pares sugeridos), `POST /api/v1/devices/:id/replace`
(`new_device_id`, `pairs: [{old, new, invert}]` ou `map: {antigo: novo}` +
`invert: [antigos]`, `retire`, `preview: true` só mostra) e
`POST /api/v1/devices/:id/replace/undo`. O app usa a tela da web (AppScreen).

**O que acontece** (uma transação): para cada par, o **ponto antigo fica**
(mesmo id, chave, nome, área, risco, histórico, ícone, exposição) e passa ao
aparelho novo levando do ponto novo `address`, `scale`, `offset`, `writable`,
`data_type`, `unit`, `min`/`max`/`step` (e as opções, em enum). Ajustes da
pessoa guardados no endereço (`stale_open_s`, `notify_s`) ficam; ponto sem
área própria fica com a área do aparelho antigo. O ponto novo duplicado é
apagado (o que já apontasse para ele se perde: a prévia avisa). Como o id do
ponto não muda, nada que aponta para ele muda. Ponto novo sem par fica como
está; ponto antigo sem par fica no aparelho antigo. Aparelho antigo
(`retire`): `remove` = `removed_at` se não sobrou ponto, senão desativado;
`disable`; `keep`. A descoberta do z2m depois não duplica (casa pelo
`json_path`, que agora está no ponto antigo).

**Sugestão** (`config/device_replace.yml`, aberto/fechado: equivalência nova
= uma linha): nota por capacidade, tipo do valor, `device_class`, unidade,
nome e propriedade equivalente (`aliases`: `doorcontact_state` ↔ `contact`,
`va_temperature` ↔ `temperature`…), escolha gulosa sem repetir ponto novo.
Par com tipo de valor incompatível é recusado.

**Inverter:** campo genérico `address.invert` (`Points::Decode.invert`),
aplicado no `Point#from_raw`/`to_raw` (Tuya, Shelly, Z-Wave, SwitchBot…) e no
MQTT (leitura e payload do comando). A sugestão compara o sentido do
verdadeiro dos dois pontos (`closed_when_true` no YAML lista as propriedades
em que o bruto verdadeiro = fechado, como o `contact` do z2m, e
`payload_on: false` desfaz isso). Atenção: a descoberta do z2m já guarda
`payload_on: false` no contato (aberto = verdadeiro, como o
`doorcontact_state` da Tuya), então do hub Tuya para o z2m **não** inverte;
um ponto MQTT feito à mão com `contact` cru é que pede inverter.

**Desfazer:** AuditEvent `device.replace` (no aparelho antigo) guarda o antes
de cada ponto e os atributos do ponto novo apagado. **Desfazer** (página do
aparelho antigo ou API) devolve os pontos com o endereço de antes, recria os
pontos novos com o mesmo id e devolve `removed_at`/`disabled`; marca
`undone_at` e grava `device.replace_undo`. Uma vez só por substituição.

**Ficar com o nome antigo** (`take_name`, caixa na tela e parâmetro na API):
o aparelho novo passa a se chamar como o antigo; num aparelho do z2m o nome
vai também para a ponte (ver "Zigbee" abaixo).

## Zigbee: assistente de pareamento, nome e rede (`Pairing`)

O que antes era feito à mão por comandos na migração dos 28 aparelhos
(`permit_join` por MQTT, ler o log do z2m, adivinhar quem entrou por
bateria/estado/ordem, `Devices::Replace` e `bridge/request/device/rename`)
virou produto. É genérico: a **capacidade de pareamento é do plugin de
integração** (`Integrations::Plugin.pairing_bridge` → adaptador
`< Pairing::Adapter`); o zigbee2mqtt é o primeiro (`Mqtt::Z2m::Bridge`).
Telas, sugestão, regra do nome e desenho do mapa ficam em `Pairing` e não
sabem de z2m. **Aberto/fechado:** outra ponte (Z-Wave JS, ZHA por MQTT…) =
adaptador com `key` (= chave do plugin), `available?`, `owns?`, `owned`,
`open!`/`close!`, `rename!`/`name_error`, `request_map!`/`graph`, `routers`
+ `pairing_bridge` no plugin; o ouvinte dele grava `PairingBridge` e
`PairingJoin`.

**Onde:** Dispositivos do local → **Parear aparelho Zigbee** (técnico+; só
aparece com broker, no local do z2m e depois de a ponte ter falado ou de
haver aparelho dela) e **Rede Zigbee** (qualquer papel). Rotas:
`/locais/:id/parear/:protocolo` (+ `ao-vivo`, `abrir`, `fechar`,
`aparelho/:join_id`, `.../novo`, `.../dispensar`) e `/locais/:id/rede/:protocolo`
(+ `mapa`). O app abre as mesmas telas pelo AppScreen (o quadro ao vivo vira
o bloco `reload`; o mapa em SVG é só da web, a tabela traz o "Ligado a").

**Assistente:**
1. **Abrir pareamento** publica `zigbee2mqtt/bridge/request/permit_join`
   `{value: true, time: 254[, device: <roteador>]}` (`value` para o z2m 1.x,
   `time` para o 2.x; "Abrir por" um roteador perto do aparelho). Abrir de
   novo renova; **Fechar** manda `time: 0`. O prazo mostrado vem do
   `bridge/info` (`permit_join_end` do 2.x ou `permit_join_timeout` do 1.x) e
   do `bridge/response/permit_join`, gravado em `pairing_bridges.permit_until`
   pelo ouvinte.
2. **Ao vivo** (quadro que se recarrega a cada 2 s): os eventos do
   `bridge/event` (`device_joined`, `device_interview` started/successful/failed,
   `device_leave`) viram `pairing_joins` (um por aparelho; entrar de novo
   recomeça a decisão) com modelo, fabricante, descrição e suportado; a
   descoberta (`bridge/devices`) liga ao aparelho daqui (`device_id`), grava
   a alimentação e assina o tópico na hora (`Mqtt::Listener.rescan!`); o sinal
   chega na primeira mensagem do aparelho. Entrevista que falhou mostra a dica
   "resete de novo perto de um roteador".
3. **Continuar** (aparelho entrevistado): **É novo** = nome + área (o nome vai
   para a ponte) ou **Substitui um aparelho existente** = lista do
   `Pairing::Suggest`, do mais provável ao menos, com os motivos: pontos que
   combinam (nota do `Devices::Replace`), bateria nos dois (ou só num: perde
   nota), mesmo estado agora nos pares verdadeiro/falso, o antigo parou de
   responder (mais nota se foi nas últimas 2 h: é o que acabou de ser
   resetado; empate = quem parou por último) e mesmo modelo. "Substituir este"
   abre a tela do Substituir já com o novo, a caixa "fica com o nome" marcada
   e a volta para o assistente; aplicar marca a entrada como resolvida (o
   desfazer reabre). **Ignorar** só tira da lista.

**Renomear de verdade (escolha: o nome vai para o z2m).** O nome daqui
continua seguindo o `friendly_name` (fonte única, tópicos e frontend do z2m
iguais), e renomear aqui (web, API, app, "É novo", "fica com o nome") publica
`bridge/request/device/rename` `{from: <ieee>, to, homeassistant_rename: true,
transaction: "ma-rename-<id>"}` (`Device` → `Pairing.renamed`, fora quando o
nome veio da própria descoberta: `bridge_naming`). Até o z2m confirmar, o
aparelho guarda `address.rename_to` e a descoberta **não** sobrescreve o nome
com o antigo; broker fora na hora = fica pendente e vai de novo ao reconectar
(`Z2m.connected`) e a cada `bridge/devices` (no máximo 1 por minuto). Se o
z2m recusa (nome em uso…), o nome volta ao de lá e a página do aparelho
mostra o erro (`address.rename_error`). Nome que o z2m não aceita (`#`, `+`,
barra no começo/fim, "/número" no fim) é recusado na validação. Por que não
a alternativa "a descoberta deixa de sobrescrever quando a pessoa renomeou":
o z2m e o MA ficariam com nomes diferentes para sempre (tópico com um nome,
tela com outro, frontend do z2m com o ieee) e renomear no z2m depois não
chegaria mais aqui.

**Rede:** `Pairing::Network` = uma linha por aparelho da ponte com papel
(coordenador/roteador/final, do `type` do `bridge/devices` em
`address.mesh.role`), alimentação, sinal (`linkquality` de cada mensagem, em
`address.mesh.lqi`, regravado só com mudança de 10+ ou a cada 5 min),
último visto, bateria (`battery_point_id`, que a descoberta agora preenche) e
situação (a disponibilidade `<nome>/availability` do z2m marca
online/offline); resumo com sinal fraco (< 40), bateria baixa (< 20%) e sem
resposta. **Atualizar mapa** pede `bridge/request/networkmap`
`{type: "raw", routes: false}`; a resposta (`bridge/response/networkmap`, pode
levar um minuto; a tela espera recarregando) fica em
`pairing_bridges.network_map` e vira grafo genérico (`Bridge.graph`) e
desenho (`Pairing::MapLayout`: coordenador no meio, roteadores no anel de
dentro, finais no de fora perto do pai; linha grossa = pai/filho; cor pelo
sinal) num SVG simples, sem biblioteca. A tela de Saúde dos aparelhos pode
linkar para `/locais/:id/rede/zigbee2mqtt`.

**Testes:** `spec/support/fake_mqtt_broker.rb` (broker falso: guarda o que
seria publicado e entrega mensagens ao ouvinte de verdade);
`spec/services/zigbee_pairing_spec.rb` e `spec/requests/zigbee_pairing_spec.rb`.
Nunca publique em MQTT real nos testes.

## Conectar (passo a passo do usuário)

**Smart Life:** no app, Eu → engrenagem → Conta e segurança → copiar o
**Código de usuário**. No local: Integrações → Tuya / Smart Life → colar →
Continuar → escanear o QR pelo app (botão de leitura no Início) → Autorizar.
A tela vai sozinha para "Dispositivos encontrados" (os Zigbee aparecem com
"pelo hub …"); marque e "Adicionar". O que já veio do LocalTuya fica em "já
no local" e continua local.

**Alexa:** Integrações → Alexa (Amazon) → país da conta → Continuar →
"Abrir o login da Amazon" (nova aba) → e-mail, senha e o código de duas
etapas, se pedir → a Amazon termina numa página de erro / "não
encontrada" (é esperado) → copie o endereço inteiro da barra e cole em
"Endereço da página depois de entrar" → Conectar. O código vale poucos
minutos; se expirar, abra o link de novo. No celular, use o navegador (o
app da Amazon não deixa copiar o endereço).

**Câmera:** Integrações → Câmera RTSP / ONVIF → RTSP (cole
`rtsp://usuario:senha@IP:porta/caminho`) ou ONVIF (IP, porta ONVIF,
usuário e senha) → Continuar → marque e "Adicionar".

**Xiaomi:** Integrações → Xiaomi → e-mail/telefone/ID, senha e servidor
(ou "Procurar em todas") → Continuar. Se aparecer a imagem, digite o texto e
a senha de novo. Se pedir duas etapas, use "Entrar com o QR code" e escaneie
pelo Mi Home.

## Cor de lâmpada e eventos do robô (Lote 8)

- **Cor** (`Points::Color`): ponto de capacidade `color`, comando `set` com
  `{"hs": [h, s]}`, `{"rgb": [r, g, b]}`, `"#rrggbb"`, `{"kelvin": k}` ou
  `{"mireds": m}` (e `"v"` 0 a 100 opcional). Como chega no aparelho vem de
  `address.color`, montado pelo mapa: `hs` = formato (`Points::Color::FORMATS`:
  `hsv_json`, `hsv_hex`, `rgb_int`; `via` troca o formato por driver, ex.: Tuya
  JSON na nuvem e hex na LAN), `temp` = endereço irmão + faixa
  (kelvin → bruto linear) e `mode` = endereço irmão do modo (`colour`/`white`).
  O driver grava tudo num pedido (`Point#raw_writes`). Tuya: `colour_data_v2`
  e `colour_data` em `tuya.yml` (irmãos por código). Xiaomi: `color` (RGB
  inteiro) e `color-temperature` (kelvin) em `miot.yml` (irmão pelo nome, no
  mesmo serviço). Na tela, o seletor de cor do navegador. Validado no Dell
  numa lâmpada Tuya 3.3 pela LAN (vermelho, 3000 K e volta ao estado inicial).
- **Eventos do robô** (`miot.yml`, `vacuum_events`): o protocolo local não
  empurra evento; cada um vira ponto `event` (`siid/eiid`, `event`) que
  dispara quando a situação (`when`: siid/piid, códigos `from` → `to`) muda
  na leitura periódica (`Miio::Vacuum.fire_events`). Limpeza começou/concluída,
  mapa concluído, base esvaziou, pano lavado e erro; mais o ponto "Limpeza
  atual" (2.40, JSON com os cômodos). Evento novo = linha no mapa.
- **Movimento da câmera Tuya**: já era ponto (`initiative_message`). O
  importador do HA liga a entidade sem aparelho (`tuya_camera_motion`) pelo
  começo do `unique_id` (= id do aparelho daqui) e pela classe do sensor.
- **Echo** (G12): comandos `sound` (id do som da Alexa,
  `amzn_sfx_doorbell_chime_01`), `play` ("PROVEDOR: busca", padrão Amazon
  Music) e `volume` (0 a 100) no ponto `speaker`, pela sessão própria
  (`Alexa::Client`). Testado só com WebMock.

## Última fala na Echo e câmera de nuvem (Lote 9)

- **Última fala às Echo** (`Alexa::LastCalled`): o histórico de voz da conta
  (`Alexa::Client#voice_history`, só leitura, no site da loja com o token
  anti-CSRF da página de atividade, como o `alexa_media`) vira atributos do
  ponto `speaker`: `last_called` (verdadeiro na Echo que ouviu, falso nas
  outras), `last_called_summary` (o que foi dito) e `last_called_timestamp`
  (ms). Lido a cada minuto (`AlexaPlugin.tick`) **só** quando alguma automação
  ligada do local tem gatilho por atributo numa Echo da conta; sem ninguém
  escutando, nada sai para a Amazon. Uso: "Alexa, boa noite" em qualquer Echo
  → gatilho `state` com `attribute: last_called_timestamp` e condição sobre
  `trigger.attrs.last_called_summary`. Atraso de até 1 min.
- **Echo completo (G12, corte)** (`Alexa::State`): na varredura/leitura
  periódica da integração, as mesmas leituras do `alexa_media`
  (`/api/devices/deviceType/dsn/audio/v1/allDeviceVolumes`,
  `/api/dnd/device-status-list` e `/api/np/player` de cada Echo ligada) viram
  pontos genéricos de cada Echo, além do "Falar" (`speaker`): **Mídia**
  (capacidade `media`: estado tocando/pausado/parado, título, artista, álbum,
  provedor, capa, volume e mudo; comandos `resume pause next previous volume
  play_media` por `/api/np/command` e pela sequência de música), **Não
  perturbe** (onoff; `PUT /api/dnd/status`) e **Último chamado** (onoff só
  leitura, marcado pelo `Alexa::LastCalled`; um gatilho nesse ponto também
  liga a leitura do histórico de voz). Ponto novo da Echo = linha em
  `Alexa::State::POINTS`. Testado só com fixture (WebMock): nenhum Echo real
  foi comandado.
- **Câmera de nuvem sob demanda**: ponto `stream` com `address.on_demand`. O
  plugin da integração do aparelho dá o endereço de agora
  (`Plugin.stream_url(point)`) e o go2rtc recebe o stream na hora do quadro
  ou do ao vivo (`Drivers::Go2rtc.prepare`); fica fora do `sync!` porque o
  endereço vence. Tuya: categoria listada em `streams` no `tuya.yml` ganha o
  ponto "Vídeo" na varredura; o endereço vem do `allocate` da API de
  compartilhamento (o mesmo do HA). Integração nova com vídeo de nuvem =
  `stream_url` no plugin.
- **Limpar cômodos por texto**: o valor do `clean_rooms` pode ser JSON ou só
  os cômodos separados por vírgula, pelo id ou pelo nome do mapa
  ("5, Cozinha"), para vir de um campo de script ou de uma consulta.

## Aparelhos da rede, mídia, Matter, IR/RF e Spotify (Pacote 1)

Nada aqui é código por marca no núcleo: cada integração é um plugin em
`Integrations::PLUGINS`, cada driver uma linha em `Drivers::REGISTRY` (e em
`Polling::DEVICES` se lê), os mapas ficam em `config/device_maps/*.yml` e o
desenho sai da capacidade do ponto.

### Peças comuns

- **`Integrations::LanPlugin`**: aparelho da rede = uma integração por
  aparelho (como no HA). `port`, `secrets` (campos cifrados na integração),
  `mdns` (serviço DNS-SD) e `probe(integration)` → uma entrada de
  inventário. Formulário comum `forms/_lan` (nome, IP, porta, segredos);
  erro de rede vira aviso na tela de encontrados.
- **Procurar na rede** (`Plugin.discovers?`/`discover`): o assistente lista o
  que se anuncia (`Mdns.browse`, ou descoberta própria como o hello do
  Broadlink) e "Usar" só preenche o IP. **Nada é cadastrado sozinho.** O
  container na rede bridge do Docker não alcança o multicast: com
  `MDNS_SUBNET` (ex.: `192.168.68.0/22`, no `.env`) o servidor também faz a
  pergunta unicast a cada IP da faixa (RFC 6762 §6.7). Conferido no Dell em
  31/10/2026: bridge sem a faixa = nada; com a faixa = HA e Matter
  respondem; rede do host = tudo (Spotify Connect etc.).
- **Capacidade `media`** (valor `{state, title, artist, album, app, source,
  volume, muted}`; comandos `on off resume pause next previous volume
  volume_up volume_down mute play_media`) e **`address.supports`**: o
  aparelho diz o que faz e `Points::Command.commands_for` corta o resto.
- **Capacidade `remote`** (controle remoto genérico, `Remotes`): códigos
  aprendidos em `address.codes` ({botão → código}); comandos `send`,
  `learn` (até 20 s) e `forget` pelo nome do botão. Transporte novo = driver
  com `send_code`/`learn` chamando `Remotes.execute`.
- **Widgets `media` e `remote`** (`Dashboards::Widgets`, também no app): o
  painel automático e a página do ponto usam o widget da capacidade
  (`describe auto:`). A Echo (`speaker`) pode usar o widget de mídia: aparece
  só o volume, o único comando dela que o widget conhece.
- `Proto` (protobuf mínimo: ESPHome, Cast), `WsClient` (WebSocket sobre o
  `websocket-driver`: webOS, Tizen, Matter) e `Device` aceitando qualquer
  driver registrado (rótulo vindo do plugin).

### Tipos

- **ESPHome** (`EsphomePlugin`, `Esphome::Client`): API nativa, TCP 6053.
  Sem chave: quadro 0x00 + varint(tamanho) + varint(tipo) + protobuf. Com a
  chave do YAML (`api: encryption: key`): Noise_NNpsk0_25519_ChaChaPoly_SHA256
  (`Esphome::Noise`, prólogo `NoiseAPIInit\0\0`, quadro 0x01 + tamanho em 2
  bytes). Senha antiga opcional; chave e senha cifradas. mDNS
  `_esphomelib._tcp`; `external_id` = MAC. Entidades → pontos pelo
  `esphome.yml` (binary_sensor pela `device_class`, sensor `measure` com
  unidade e `state_class`, switch `onoff`, light `onoff` + `dimmer`, number
  `setpoint`, button `command`, text_sensor `text`, cover `setpoint` 0–100 %,
  crítico em garagem/portão); endereço `{key, kind, …}`. Tempo real pelo
  `Esphome::Listener` no worker (uma conexão por aparelho; caiu =
  `unavailable`, volta em até 60 s; `ESPHOME_LISTENER=off`). Fora: fan,
  climate, lock, select, valve, media_player e cor da luz. O Noise foi
  conferido só contra o responder do spec.
- **Shelly** (`ShellyPlugin`, `Shelly`): mDNS `_shelly._tcp`; geração pelo
  `/shelly`. Gen1 por HTTP (`/settings`, `/status`, `/relay|light|roller/N`,
  Basic) e Gen2+ por RPC JSON em `POST /rpc` (Digest SHA-256, usuário
  `admin`). Relé/luz `onoff`, brilho `dimmer`, persiana (posição `setpoint` +
  movimento `enum`), potência, tensão, corrente e energia (kWh,
  `total_increasing`) pelo `shelly.yml`. Leitura a cada 30 s e depois de cada
  comando. Fora: tempo real (CoAP/WebSocket).
- **Tasmota** (`TasmotaPlugin`, `Mqtt::Tasmota`): pelo broker do servidor,
  com a descoberta nativa (`SetOption19 0`): `tasmota/discovery/<MAC>/config`
  e `/sensors` viram aparelho `mqtt` (relé em `stat/<t>/RESULT` →
  `cmnd/<t>/POWERn`, brilho com `lt_st`, cada número do `tele/<t>/SENSOR`
  com nome e unidade do `tasmota.yml`). Os descobridores MQTT viraram
  registro: `Mqtt::Listener::DISCOVERY` (`Z2m`, `Tasmota`; módulo com
  `topics`, `handles?`, `handle`). Fora: persiana (`rl` 3).
- **Matter** (`MatterPlugin`, `Matter::Client`): cliente do
  python-matter-server (o mesmo do HA) por WebSocket. Serviço opcional
  `matter-server` no compose, desligado (`docker compose --profile matter up
  -d matter-server`, rede do host; o worker fala em `ws://<IP>:5580/ws`).
  Nós → aparelhos `matter`; atributos → pontos pelo `matter.yml` (liga/
  desliga, nível, temperatura, umidade, ocupação, abertura, iluminância,
  bateria, potência, cortina); endereço `{node, endpoint, cluster,
  attribute}`; comando por `device_command`. **Comissionar**: em
  Reconfigurar, cole o código (MT:… ou 11 dígitos) com o aparelho já na rede
  (`network_only`). Tempo real pelo `Matter::Listener`
  (`MATTER_LISTENER=off`). Fora: energia acumulada (estrutura), Bluetooth,
  ventilador, ar e fechadura.
- **Mídia na rede** (`MediaLanPlugin`, `Drivers::MediaLan`): ponto `media`
  lido a cada 60 s; TV que não responde = "Desligada". "Ligar" por
  Wake-on-LAN só com o MAC (o broadcast UDP não sai da rede bridge).
  - **Chromecast** (`cast`, `_googlecast._tcp`, 8009): CastV2 em TLS com
    protobuf; volume, mudo, app, título, play/pausa, próxima/anterior, parar
    e tocar endereço (Default Media Receiver).
  - **LG webOS** (`webos`, 3000/3001): SSAP; volume, mudo, app, play/pausa,
    desligar e abrir endereço; client-key cifrado.
  - **Samsung Tizen** (`tizen`, 8002/8001): teclas do controle; estado por
    `/api/v2/`; sem volume exato nem tocar endereço; token cifrado.
  - **Android TV / Fire TV por ADB** (`adb`, 5555): chave RSA da integração
    (cifrada), `input keyevent`, `am start` para tocar endereço e estado por
    `dumpsys`.
- **Broadlink** (`BroadlinkPlugin`, `Broadlink`): RM mini/RM4/Pro por UDP 80
  (cabeçalho 0x38 com checksum, AES-128-CBC, `auth` 0x65). "Procurar na
  rede" pelo hello (broadcast e, com `MDNS_SUBNET`, unicast). Ponto
  "Controle" (`remote`); o RM4 Pro ganha temperatura e umidade. Modelo novo =
  linha no `broadlink.yml`. Fora: varredura de RF (0x19–0x1E).
- **IR da Tuya** (hub `wnykq`): `remotes` no `tuya.yml` dá ao hub o ponto
  "Controle"; envio pelo dp 201 (`send_ir`) e aprendizado pelo `study`, com o
  código no dp 202, pela rede local (`tuya_local`). Os controles virtuais
  `infrared_tv`/`infrared_ac` continuam sem pontos (a nuvem de
  compartilhamento não manda tecla IR; ver d61fd1b). Fora: aprender com o
  ouvinte Tuya ligado no mesmo hub.
- **Spotify** (`SpotifyPlugin`, `Spotify`): OAuth com o app da própria
  pessoa (client id e secret cifrados; retorno genérico
  `/integracoes/oauth/retorno`). Aparelho virtual `spotify:<integração>` com
  ponto `media` (`resume pause next previous volume play_media`; URI
  `spotify:…` ou link `open.spotify.com`), leitura a cada 30 s e token
  renovado sozinho. "Tocar playlist" numa automação = "Comandar ponto" com
  `play_media`. Fora: escolher o aparelho de destino; ligar e mudo (a API não
  tem).

### O que depende de quem instala

- **LG**: aceitar o pedido na TV na primeira leitura (até 1 min); para ligar
  pela rede, "Ligar via Wi-Fi/LAN" na TV. **Samsung**: "Permitir" na TV (30
  s). **Android TV**: modo desenvolvedor, "Depuração de rede" e "Permitir
  depuração? Sempre" (30 s). Chromecast não pede nada.
- **Spotify**: developer.spotify.com/dashboard → Create app → Web API →
  Redirect URI `https://<host>/integracoes/oauth/retorno` → copiar Client ID e
  Secret → Integrações → Spotify → "Entrar com o Spotify". Em "Development
  mode" só as contas cadastradas em User Management entram; controlar exige
  Premium.
- **Broadlink**: aparelho desbloqueado no app Broadlink.
- **Matter**: subir o `matter-server` (perfil) e comissionar pelo código.
- **ESPHome**: a chave `api: encryption: key` do YAML da placa.

## Ecossistema ampliado (integ, 2026-11)

### Ponte Matter (expor) e pontes de exposição

- Registro genérico `Bridges::PLUGINS` (`app/services/bridges.rb`): cada ponte
  descreve os tipos de aparelho em `TYPES` (`applies`, `state`, `commands`).
  A escolha dos pontos fica em `bridge_exposures` (ponto, ponte, nome; ponto
  crítico só com confirmação), tela `/locais/:id/pontes/:ponte` (aba
  "Matter") e API do serviço `GET /api/v1/bridges/:ponte`,
  `PUT …/status` e `POST …/commands` (chave de integração gerada na tela, só
  ler e comandar o local). Comando vindo da ponte tem origem `bridge`.
- `Bridges::MatterBridge`: liga/desliga (luz ou tomada), luz com intensidade,
  luz colorida (hs; liga/desliga pelo ponto irmão), cortina (posição em %,
  invertida para o Matter), termostato (setpoint em °C), fechadura (portão:
  trancar = fechar), abertura, presença, temperatura e umidade.
- Serviço `matter-bridge/` (Node 22 + matter.js 0.17.9), perfil
  `matter-bridge` do `docker-compose.local.yml`, desligado:
  `docker compose --profile matter-bridge up -d --build matter-bridge`, com
  `MATTER_BRIDGE_KEY` no `.env`. Rede do host, porta 5540, pareamento no
  volume `matter-bridge-data`. Lê a lista a cada 3 s; QR e código aparecem
  na aba. Teste: `cd matter-bridge && npm test` (todos os tipos sobem, eco
  não volta, mudança de fora vira comando); o contrato com o Rails é o
  `matter-bridge/fixture.json` (conferido também no RSpec).

### Câmeras com IA (capacidade `detection`)

- Capacidade genérica `detection` (json, só leitura, conta a cada aviso como
  `event`): `{kind (person/vehicle/animal/package/face/other), label, score
  0–100, zones, id, at, clip?}` (`Detections`). Gatilho "Câmera detectou"
  (`DetectionTrigger`: tipo, zona, confiança mínima). No "Avisar", o campo
  câmera aceita o ponto de detecção: o quadro vem do plugin
  (`Plugin.snapshot(point)` → `Integrations.snapshot`), também em
  `GET /api/v1/points/:id/snapshot`.
- **Frigate** (`FrigatePlugin`, `Frigate`): `/api/config` → um aparelho por
  câmera (detecção + "Pessoa/Veículo… na câmera"); eventos pela API (10 s) e,
  com broker, MQTT `<tópico>/events` e `<tópico>/<câmera>/<rótulo>`
  (`Mqtt::Listener::DISCOVERY`). Quadro com caixa e link do clipe.
- **Reolink** (`ReolinkPlugin`, `Reolink`): `/api.cgi` com token; um aparelho
  por canal; `GetAiState` (pessoa, veículo, animal) e `GetMdState` a cada 5 s;
  quadro pelo `Snap`.
- **UniFi Protect** (`UnifiProtectPlugin`, `UnifiProtect`): usuário local do
  console, cookie + CSRF; `bootstrap`, eventos `smartDetectZone` e
  `/cameras/:id/snapshot`.

### Luz e casa, energia

- **Philips Hue** (`HuePlugin`, `Drivers::Hue`): API v2 local, pareamento pelo
  botão (chave cifrada), mDNS `_hue._tcp`; luz (liga, brilho, cor xy ↔ hs),
  movimento e temperatura; leitura a cada 15 s.
- **WLED** (`WledPlugin`, `Drivers::Wled`): JSON API, mDNS `_wled._tcp`; liga,
  brilho 0–255, cor e efeito.
- **Yeelight** (`YeelightPlugin`, `Drivers::Yeelight`): TCP 55443 (Controle
  pela LAN); liga, brilho e cor.
- **SwitchBot** (`SwitchbotPlugin`, `Drivers::Switchbot`): API de nuvem v1.1
  assinada (token e segredo do usuário); tipos → pontos pelo
  `config/device_maps/switchbot.yml` (bot, tomada, cortina, termo-higrômetro,
  movimento, abertura, lâmpada, fechadura); leitura a cada 5 min.
- **Shelly EM** Gen2+ (Pro 3EM, Pro EM, EM Gen3): componentes `em`, `emdata`,
  `em1` e `em1data` no `shelly.yml` (só dado).
- `LanHttp`: HTTP comum dos aparelhos da rede (JSON, timeout curto, 401/403 =
  Reconfigurar, `insecure` para certificado próprio). `LanPlugin.plain`:
  campos às claras no formulário (usuário).

### Ficou de fora (próximas)

Tempo real da Hue (SSE; hoje leitura a cada 15 s), descoberta SSDP da
Yeelight, Deye/Solarman e SolarEdge/Fronius pela nuvem; no app Flutter, a
capacidade `detection` aparece como texto genérico. (Ar-condicionado,
SunSpec, Growatt, Dirigera, Sonos, Govee, Z-Wave JS e proxy Bluetooth
entraram no integ2, abaixo.)

## Ecossistema 2 (integ2, 2026-11)

Tudo como plugin de `Integrations::PLUGINS` + driver em `Drivers::REGISTRY`
(e `Polling::DEVICES`); mapas em `config/device_maps/`. Spec:
`spec/services/integ2_spec.rb` (respostas gravadas e aparelhos de mentira em
127.0.0.1, AC falso por `stub_const`) e `spec/requests/integ2_spec.rb`.
`Drivers.refresh(integração)` lê os aparelhos logo depois da adoção.

### Ar-condicionado (capacidade `climate`)

- Base `Drivers::Climate` + `config/device_maps/climate.yml`: todo AC ganha os
  mesmos pontos (Liga/desliga, Temperatura alvo em °C — vira termostato na
  Alexa e na ponte Matter —, Modo, Ventilação, Temperatura ambiente) e o
  resumo `climate` (json, só leitura: `{power, target, mode, fan, current}`).
  O fabricante só lê o estado e grava um campo; os códigos de modo e
  ventilação de cada um ficam em `vendors` do mapa. Fabricante novo = bloco no
  mapa + subclasse com `vendor`, `read` e `write`.
- **Daikin** (`DaikinPlugin`): adaptador BRP069/BRP072, HTTP local
  (`get_control_info`/`set_control_info`; o set leva o controle inteiro e, ao
  trocar o modo, a temperatura guardada daquele modo).
- **Midea** (`MideaPlugin`, `Midea::Session`): protocolo local V3 na TCP 6444
  (aperto de mão com token + chave → chave da sessão; envelope 0x8370
  AES-CBC/SHA-256, pacote 0x5A5A AES-ECB/MD5, quadro 0xAA com CRC-8). Id,
  token e chave saem uma vez da conta com o `msmart-ng discover`; token e
  chave cifrados. O comando 0x40 grava o estado inteiro.
- **LG ThinQ** (`LgThinqPlugin`): API oficial ThinQ Connect (região Américas),
  token de acesso pessoal (PAT) cifrado, país em `x-country`. Só os
  `DEVICE_AIR_CONDITIONER` da conta; o comando grava o pedido sem reler.

### Solar (alimenta os painéis de energia)

- **SunSpec / Modbus TCP** (`SunspecPlugin`, `Modbus`, `Drivers::Sunspec`):
  acha "SunS" (40000, 0 ou 50000), lê o modelo comum (fabricante, modelo,
  série) e o do inversor (101–103) com fator de escala: potência (W),
  energia gerada (kWh, `total_increasing`), tensão, frequência, potência CC,
  temperatura e estado. Só leitura (função 3).
- **Growatt** (`GrowattPlugin`): OpenAPI v1 com o token da conta; cada usina
  vira aparelho com potência, energia do dia e total (a cada 5 min).
- A potência entra direto no papel "Geração solar" do painel de energia
  (`EnergyFlowWidget`/`EnergyPreset`).

### Casa e mídia

- **IKEA Dirigera** (`DirigeraPlugin`): API local HTTPS 8443; pareamento OAuth
  PKCE em dois passos com o botão de ação (token cifrado); tipos → pontos por
  `config/device_maps/dirigera.yml` (luz, tomada com medição, persiana,
  purificador, sensores de ambiente, movimento, abertura e vazamento);
  comando por `PATCH /v1/devices/:id`.
- **Sonos** (`SonosPlugin`, `Drivers::Sonos < MediaLan`): UPnP/SOAP na 1400,
  mDNS `_sonos._tcp`; ponto `media` comum (o que toca, volume, mudo; tocar,
  pausar, avançar, voltar, volume e tocar um endereço).
- **Govee** (`GoveePlugin`): API LAN por UDP (scan multicast na 4001,
  respostas na 4002, comandos na 4003); "Procurar na rede" pelo scan próprio;
  liga, brilho e cor.

### Z-Wave JS e Bluetooth

- **Z-Wave JS** (`ZwaveJsPlugin`, `ZwaveJs::Client`): cliente do
  zwave-js-server pelo WebSocket (`set_api_schema`, `start_listening`,
  `node.set_value`). Valores → pontos por classe de comando em
  `config/device_maps/zwave.yml` (relé, dimmer, sensor binário, sensor
  multinível, medidor, setpoint de termostato, bateria). Inclusão de nós
  continua no Z-Wave JS UI.
- **Proxy Bluetooth** (`BleProxyPlugin`, `Drivers::BleProxy`, `Ble`): a placa
  ESPHome com `bluetooth_proxy` repassa os anúncios crus (assinatura 66 →
  mensagens 93) pela API nativa (com Noise). Decodificadores em `Ble::DECODERS`:
  BTHome v2 sem criptografia, termômetros Xiaomi pvvx e ATC1441, Govee
  H5072/H5075. A varredura ouve 10 s; a leitura ouve até 30 s e atualiza
  todos os sensores vistos.

### Limites conhecidos (integ2)

- Todos conferidos só contra respostas gravadas/aparelhos de mentira, não
  contra aparelho ou conta real. O protocolo Midea foi escrito a partir do
  msmart-ng (V2 e descoberta UDP 6445 ficaram de fora).
- Sem tempo real: AC a cada 1–2 min, Dirigera/Govee a cada 30 s, Z-Wave a cada
  5 min (sem ouvinte de eventos), Bluetooth a cada 5 min.
- BTHome cifrado, Xiaomi MiBeacon (cifrado) e a classe Notification do Z-Wave
  (sensores de movimento novos) não são lidos ainda.
- Govee: o estado volta na UDP 4002 do servidor (rede `host`); dois pedidos
  ao mesmo tempo dividem a porta.

## Protocolos e ecossistemas (ondaC1, 2026-11)

Paridade com o grupo 5 do HA. Tudo por registro, com spec de plugin falso.

- **Tela "Gerenciar" da integração** (`Plugin.panel?`, `panel_locals`,
  `panel_action`, `panel_refresh`): partial `web/integrations/panels/_<key>`
  ou a genérica (`stats`, `rows`, `actions`). Rotas
  `/integracoes/:id/gerenciar` e `/integracoes/:id/gerenciar/:acao`.
- **Z-Wave JS completo**: inclusão S2 (concede as classes pedidas, PIN do
  DSK), só S2, sem segurança, SmartStart pelo QR, exclusão, refazer rotas,
  remover nó com falha, reentrevistar, mapa da rede pelos vizinhos, valores
  em tempo real (`ZwaveJs::Listener`, `ZWAVE_LISTENER=off` desliga),
  Notification CC (113) e Central Scene (91) no `zwave.yml`, firmware pelo ar
  (`Firmware::Providers::ZwaveJs`). A inclusão corre no worker; a tela fala
  com ele pelo cache (`ZwaveJs::Inclusion`).
- **Bluetooth**: formatos em `Ble::PARSERS` (BTHome com e sem chave,
  Xiaomi MiBeacon com bindkey, pvvx, ATC, Govee, iBeacon, Oral-B). Adaptador
  do servidor: `bin/ble-scan` (HCI cru, escuta passiva) no serviço
  `ble-scanner` (perfil `bluetooth`) → `POST /api/v1/bluetooth/advertisements`
  (chave `write` gerada no Gerenciar) → `Ble::Hub` em tempo real. Chaves
  "MAC=chave" nos segredos (proxy ESPHome e adaptador).
- **Matter**: Gerenciar com servidor, comissionar pela rede ou pelo
  Bluetooth do servidor, Wi-Fi e Thread para comissionar, compartilhar
  (multi-admin, QR e código por 3 min, fabrics do nó), reentrevistar,
  remover; firmware pela DCL (`Firmware::Providers::Matter`). Pelo Bluetooth
  do celular: onda D (app).
- **Thread**: integração do OpenThread Border Router (REST 8081, serviço
  `otbr`, perfil `thread`): papel, rede, dataset cifrado, formar rede,
  importar dataset, rede preferida e credenciais para o Matter.
- **MQTT discovery do HA**: `homeassistant/<componente>/…/config` e o
  formato de aparelho (`cmps`), componentes em
  `Mqtt::HaDiscovery::COMPONENTS`, templates Jinja, disponibilidade, birth
  message; zigbee2mqtt e Tasmota não duplicam.
- **HomeKit**: ponte para o app Casa (`Bridges::HomekitBridge` + serviço
  `homekit-bridge/` com hap-nodejs, perfil `homekit`) e controlador nativo
  em Ruby (`Hap::Client`, integração "HomeKit (aparelhos)", mapa
  `homekit.yml`).
- **Google Home cloud-to-cloud**: `POST /google/smart_home`, traits em
  `GoogleHome::Traits`, OAuth comum (`OauthClients`), HomeGraph pela conta
  de serviço, estado aos ecossistemas por `StateReport::REPORTERS`. Passo a
  passo do dono em `docs/google-home.md`.


## Integrações dos aplicativos (apps, 11/2026)

Plugins para os apps do catálogo (`config/apps/*.yml` com `connect`); todos
`SchemaPlugin` (formulário gerado, sem partial própria). Spec:
`spec/services/apps_onda_spec.rb`.

| Plugin | O que faz |
|---|---|
| `speedtest_tracker` | `GET /api/v1/results/latest` (token Bearer do Speedtest Tracker): download/upload (Mbit/s, de `*_bits` ou bytes/s), latência e `last_test` (`datetime`). Leitura a cada 10 min; quem mede é o app. |
| `adguard` (já existia) | Proteção e filtros como chaves; consultas, bloqueadas e %. "Pausar" = comandar o ponto Proteção. |
| `ntfy` | Mensageiro (`send_message`): canal `messenger:<id>`. Detalhes em `docs/push.md`. |
| `double_take` | Um aparelho por pessoa ("Rosto: Nome"), pontos `seen` (movimento/ocupação com `hold_s`, rastreador `Face`), `camera` e `last` (evento). Lido pelo descobridor MQTT `::DoubleTake` (`<tópico>/matches/<nome>`), que também dispara o evento `face_recognized` ({name, camera, confidence, zones}). |
| `owntracks` | `GET /api/0/last` do Recorder; um aparelho por usuário/celular com "Presença" (`text`, `device_class: location`, valor = zona) e bateria. Coordenada só nos atributos e apagada pelo `tick` depois de `location_keep_h`. |
| `espresense` | Aparelhos listados (`id = nome`) com "Cômodo atual" (rastreador `Room`) e distância; cômodos listados com "Ocupado". Descobridor `::Espresense` (`<tópico>/devices/<id>/<cômodo>` e `<tópico>/companion/<id>`), estado em memória, banco só quando o cômodo muda; a leitura de 60 s tira quem sumiu (`not_home`). |
| `influxdb` (mudou) | Exportação **em lote pelo relógio** (`tick` a cada minuto): lê as `readings` novas desde `settings.exported_at`, até 5000 linhas por pedido; saiu do `StateReport` (nenhuma tarefa por leitura). Falhou = cursor parado, atraso máximo de 1 dia. |
| `grafana` | Conectar cria/atualiza pela API a fonte de dados `minha-automacao` (InfluxDB Flux, token cifrado no Grafana) e o painel "Minha Automação" (°C, %, W, Mbit/s). |

Descobridor MQTT novo = módulo com `topics`/`handles?`/`handle` + nome em
`Mqtt::Listener::DISCOVERY` (aqui: `DoubleTake`, `Espresense`).
