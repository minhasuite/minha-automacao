# Câmeras

Toda câmera é um aparelho `go2rtc` com um ponto `stream` por vídeo (perfil
ou canal). O vídeo nunca vai direto do navegador para a câmera: o
`Go2rtcSyncJob` (a cada minuto) põe um stream por ponto no go2rtc do
servidor (nome = id do ponto) e a tela pede ao Rails o quadro
(`GET /cameras/:id/quadro`) e o ao vivo por WebRTC
(`POST /cameras/:id/ao-vivo`), com o papel no local. Sem `GO2RTC_URL` (VPS)
o widget mostra "Sem conexão". Câmera de nuvem ou caída não segura a tela: o
quadro vem em segundo plano e a resposta sai na hora (último quadro ou 503);
`?w=` pede um quadro menor (`docs/desempenho.md`).

## De onde vem a câmera (plugins de integração)

| Plugin | Para quê | Aparelho |
| --- | --- | --- |
| `CameraPlugin` "Câmera RTSP / ONVIF" | qualquer câmera IP | um `go2rtc`; RTSP = um ponto; ONVIF = um ponto por perfil + `motion` se houver eventos |
| `TapoPlugin` "Câmera Tapo (TP-Link)" | câmera Tapo da rede (ONVIF na 2020) | um `go2rtc` como o do ONVIF + recursos do modelo (`tapo.yml`) e, opcional, controles pela API local |
| `HikvisionPlugin` "Câmeras / DVR" | DVR/NVR Hikvision pela ISAPI | um `go2rtc` com um ponto por canal (substream) |
| `TuyaPlugin` (Smart Life) | câmera Tuya (categoria `sp`) | `tuya_local` com os dps do mapa: movimento, sirene, holofote, privacidade |

Tipo novo de câmera = plugin de integração cujo inventário devolve uma
entrada `kind: "go2rtc"` (spec "plugins falsos" em `spec/services/lote3_spec.rb`).

## Endereço do aparelho e do ponto

- Aparelho: `address` {scheme (`rtsp` padrão, `rtsps`), host, port (554),
  username, onvif_port}; `credential` = senha (cifrada). A URL RTSP com
  senha só existe na hora de falar com o go2rtc (`Drivers::Go2rtc.source`),
  nunca no banco, em log ou na tela.
- Ponto `stream`: `address` {path (caminho + consulta), port? (quando o
  perfil usa outra porta)}.
- Ponto `motion` ONVIF: `address` {onvif: "motion"}.

Prefira o substream (perfil menor) e RTSP sobre TCP (padrão do go2rtc).
Usuário sem senha fica fora do go2rtc (DVR bloqueia o usuário com senha
errada).

## Movimento

- **ONVIF** (`Onvif::Listener`, no worker; `ONVIF_LISTENER=off` desliga):
  uma thread por câmera com ponto `motion` ONVIF. Assina por
  `CreatePullPointSubscription`, pede mensagens em espera longa (20 s),
  renova a cada 5 min e lê o tópico com "motion" e o item `IsMotion`,
  `State` ou `Motion`. Caiu: o ponto fica `unavailable` e tenta de novo
  (até 60 s). WS-Security com digest e o relógio acertado pelo da câmera.
- **Tuya** (dados em `config/device_maps/tuya.yml`): o dp
  `initiative_message` (base64 de JSON) com `cmd: ipc_motion` liga o ponto
  "Movimento", que volta a falso 30 s depois do último aviso
  (`hold_s`, `PointHoldJob`). Só conta quando a câmera empurra o dp
  (`push_only`): precisa do ouvinte Tuya (`devices.listen`) ligado no
  aparelho. A câmera Tuya não fica no LocalTuya do HA, então ligar o
  ouvinte nela não briga com o HA.

## Sirene e holofote

Pontos `onoff` comuns. A sirene nasce com risco **crítico** (o mapa diz
`risk: critical`): comando só para morador ou acima e, na Alexa, só com a
confirmação de risco. Nunca acione sirene de teste.

## Snapshot no aviso e na IA

A ação "Avisar" (`camera`) e "Pedir à IA" (`cameras`) usam o quadro do
go2rtc de qualquer ponto `stream`, de qualquer plugin.

## PTZ, gravação e falar (ondaC2)

Na página do ponto de vídeo (`/pontos/:id`) e no app (câmera em tela cheia):

- **PTZ**: comando `ptz` no ponto `stream` (`left`, `right`, `up`, `down`,
  `zoom_in`, `zoom_out`, `home` ou `preset:<token>`), pelo ONVIF da câmera
  (`ContinuousMove` de 1 s com Timeout, `GotoHomePosition`, `GotoPreset`;
  `Drivers::Camera`). A descoberta ONVIF marca `ptz` quando a câmera tem o
  serviço; dá para ligar à mão em "Ajustes da câmera".
- **Gravação própria** (`Recordings`): `address.record` {mode `off` |
  `continuous` | `events`, `retention_days`, `event_s`}. O go2rtc entrega o
  MP4 (`/api/stream.mp4?duration=`) e o arquivo fica em
  `RECORDINGS_DIR/<local>/<ponto>/<dia>/` (padrão `storage/recordings`), com
  o índice em `camera_recordings`. Contínua: `Recordings::Recorder` no worker
  (trechos de 60 s; `RECORDINGS=off` desliga). Por evento: um ponto `motion`
  do mesmo aparelho ligando grava `event_s`. Na hora: comando `record`
  (segundos). Retenção: `RecordingsPurgeJob` a cada hora. As gravações
  aparecem em Mídia → Gravações das câmeras (ver, ou mandar para a TV).
- **Falar (áudio de duas vias)**: "Tem alto-falante" liga `play_media` no
  ponto. Na web, "Falar" refaz o ao vivo WebRTC mandando o microfone (o
  go2rtc repassa pelo backchannel da câmera). No app, segura e fala: o áudio
  vai por `POST /api/v1/points/:id/talk` e o go2rtc toca
  (`POST /api/streams?dst=<ponto>&src=ffmpeg:<url>`). A câmera também vira
  canal de fala (ação "Falar", avisos).

## Câmeras Tapo (TP-Link)

Plugin `TapoPlugin` (`< LanPlugin`, uma integração por câmera). Por baixo é
o mesmo caminho das câmeras ONVIF: `Onvif.inventory` na porta **2020** com a
**conta da câmera**, aparelho `go2rtc`, um ponto `stream` por perfil
(`/stream1` = "Vídeo (alta)", `/stream2` = "Vídeo (baixa)"), movimento e
outros eventos pelo `Onvif::Listener` e PTZ pelo `Drivers::Camera`. O que é
da Tapo:

- **Recursos por modelo** em `config/device_maps/tapo.yml` (`Tapo.preset`,
  prefixo mais longo do modelo que o ONVIF informa): `ptz`, `siren`,
  `two_way_audio`, `spotlight`, `rtsp` e `streams` extras (lente tele da
  C246D/C840 em `/stream6` e `/stream7`). Viram `address.supports` dos
  pontos de vídeo e `address.features` do aparelho. Modelo novo = linha no
  YAML. Modelo com `rtsp: false` (bateria C4xx, campainha D230, o que fica
  atrás do hub H200) é recusado com o aviso.
- **Falar** (senha da nuvem preenchida e modelo com `two_way_audio`): o
  vídeo principal ganha `address.talk` e o comando `play_media`; o
  `Go2rtcSyncJob` põe o stream com duas fontes, o RTSP e o
  `tapo://<senha da nuvem>@IP` (o PUT do go2rtc 1.9.9 aceita `src` repetido;
  `Plugin.extra_sources(point)`). O vídeo continua vindo do RTSP; o `tapo://`
  dá o áudio de volta (o ONVIF da Tapo é só Profile S, sem áudio de volta;
  codec PCMA/8000, o mesmo do `play_audio`).
- **Controle pela API local** (`Tapo::Client`, opcional): HTTPS 443 da
  câmera, usuário `admin` + senha da nuvem, no formato do pytapo (o mesmo
  do `tapo_control` do HA). Login seguro (`encrypt_type` 3: cnonce →
  nonce + `device_confirm`, `digest_passwd`, pedidos AES-CBC em
  `securePassthrough` com `Seq`/`Tapo_tag`) ou o antigo (MD5, às claras).
  Pontos `onoff` com `address.tapo` (tipos em `controls` do `tapo.yml`):
  **Modo privacidade** (`setLensMaskConfig`), **LED de status**
  (`setLedStatus`), **Detecção de movimento** (`setDetectionConfig`) e
  **Sirene** (alarme manual `do`/`manual_msg_alarm`, risco **crítico**; só nas
  famílias com `siren`). Entram só com as três chaves: senha da nuvem, caixa
  "Controlar pela API local" e o `FeatureFlag` `tapo_control` (interruptor
  geral; desligado, a varredura não cria os pontos e o comando recusa).
  Comando e leitura passam pelo plugin (`camera_command`/`camera_poll`,
  chamados pelo `Drivers::Camera` para ponto que não é vídeo); o aparelho
  nasce com leitura a cada 5 min (`go2rtc` está no `Polling::DEVICES`; câmera
  sem controle não lê nada). Leitura que falha deixa só os controles
  indisponíveis (vídeo e movimento seguem com go2rtc e ONVIF). Ligar o
  controle depois (Reconfigurar) põe os pontos no aparelho já adotado na
  próxima varredura (`Integrations::IDENTITY` inclui `tapo`).
- **Procurar na rede**: pelo nome que a câmera pede ao roteador (DHCP
  `c200_xxxx`, `tc70_xxxx`, `d230_xxxx`, os mesmos do manifesto do
  `tapo_control`); só lista e preenche o IP.

### Passo a passo (dono)

1. **IP fixo**: no roteador, reserve um IP para a câmera (DHCP estático pelo
   MAC). Sem isso o go2rtc perde a câmera quando o IP muda.
2. **Conta da câmera**: no app Tapo, abra a câmera → engrenagem →
   **Configurações avançadas → Conta da câmera** e crie usuário e senha
   (só letras e números evitam problema no RTSP). É a conta do RTSP e do
   ONVIF, diferente da conta TP-Link.
3. (Opcional, para falar e controlar) **Senha da nuvem** = a senha da conta
   TP-Link do app. Em firmware de 2024 em diante, ligue no app **Eu → Tapo
   Lab → Compatibilidade com terceiros** (sem ela a câmera recusa o login
   local e o MA mostra esse aviso).
4. No MA: **Integrações → Câmera Tapo (TP-Link)** → IP (ou "Procurar na
   rede"), porta **2020**, usuário e senha da conta da câmera; senha da nuvem
   e "Controlar pela API local" se quiser → Continuar → marque a câmera →
   **Adicionar**.
5. A Tapo aceita só duas destas três ao mesmo tempo: Tapo Care, gravação no
   cartão e NVR/ONVIF (o MA conta como NVR). Se o vídeo não abrir, desligue
   uma das outras.

### Limites e o que falta conferir com a câmera de verdade

Tudo foi conferido só com WebMock (ONVIF e uma câmera de mentira que faz o
login seguro). Falta ver numa Tapo real: o tópico do movimento no PullPoint
(`CellMotionDetector`, esperado), PTZ pelo ONVIF da 2020, a fonte `tapo://`
com a senha da nuvem em firmware novo (o go2rtc pode pedir
`admin:<SHA-256 em maiúsculas>`), o login local com "Compatibilidade com
terceiros" ligada e a duração da sirene (o ponto fica ligado até "desligar";
a câmera para sozinha no tempo do app). Firmware que só fala o login novo
(TPAP/SPAKE2+) não é suportado: a mensagem pede a "Compatibilidade com
terceiros". Holofote (`spotlight`) só está declarado no mapa, sem comando.
Câmera de bateria e atrás do hub H200 não têm RTSP/ONVIF: ficam de fora.

## Tela de Câmeras, ao vivo fora de casa e gravações do DVR (cameras2)

### Ao vivo fora de casa

O WebRTC entrega a mídia pela porta 8555 do servidor, anunciada em `APP_HOST`:
só a rede de casa chega nela. Pelo acesso externo (`casa-automacao.minhasuite.com`,
túnel HTTP reverso) a oferta SDP passa, mas o vídeo não. Por isso há dois
caminhos que passam pelo próprio Rails:

- **MSE por WebSocket** (web): `GET /cameras/:id/mse` com `Upgrade: websocket`.
  O controller confere sessão, papel no local (qualquer papel, como o
  `/quadro`), origem (`Origin` = o host do pedido: outro site não abre o
  WebSocket com o cookie) e a vaga do limite; toma a conexão do Puma (Rack
  hijack: a thread do Puma volta na hora) e o `Cameras::WsProxy` abre
  `/api/ws?src=<stream>` no go2rtc com a mesma `Sec-WebSocket-Key` do navegador
  (o 101 do go2rtc vale para ele) e só copia bytes, numa thread própria. Nada de
  Action Cable. Túnel: o vídeo não para de passar; conexão sem byte por 30 s
  fecha, e nenhuma passa de 30 min (o navegador abre de novo sozinho).
- **HLS** (app e Safari sem MSE): `GET /cameras/:id/hls` (web, sessão) ou
  `GET /api/v1/cameras/:id/hls` (app) devolvem um caminho assinado
  `/cameras/:id/hls/<token>/stream.m3u8` (`Cameras::HlsToken`: ponto, pessoa e
  stream; 6 h). O player não leva sessão nem cabeçalho; os endereços relativos do
  go2rtc (`hls/playlist.m3u8?id=…`, `init.mp4`, `segment.m4s`) caem embaixo do
  token. O índice principal confere de novo a pessoa e o papel, ocupa uma vaga e
  prende a sessão HLS do go2rtc ao token (cache); os pedaços só passam com essa
  sessão. HLS fMP4 só de vídeo (`mp4=`), pedidos curtos (bom para o túnel).
- **Limite por pessoa** (`Cameras::Streams`): `CAMERA_STREAMS_PER_USER`
  (padrão 8) vídeos pelo proxy ao mesmo tempo; vaga renovada enquanto o vídeo
  passa e solta ao fechar ou 45 s sem uso. Excedente: 429 (o card fica na foto).
  Fica no cache (Solid Cache: vale para os processos do Puma).

**Cliente web** (`camera_controller.js`): tenta WebRTC; sem vídeo em 4 s cai para
o MSE pelo proxy (protocolo do `video-rtc.js` do go2rtc: manda os codecs, recebe
`{type: "mse"}`, junta os pedaços num `SourceBuffer` perto do vivo); sem MSE
(`MediaSource`/`ManagedMediaSource`), o HLS nativo. Depois de um WebRTC que não
conectou, a página vai direto ao MSE por 5 min (as outras câmeras não esperam).
"Falar" precisa do WebRTC (o microfone vai por ele): fora de casa avisa
("só na rede de casa") e segue com o vídeo; no app o falar é o `POST /talk`, que
funciona de qualquer lugar.

**App** (`LiveCamera`): mesma ordem; o fallback é o HLS tocado pelo
`video_player` (ExoPlayer/AVPlayer tocam HLS sem nada a mais, não há MSE no app e
o WebSocket+MSE exigiria um player próprio). Escolhido por ser o caminho mais
simples e seguro: só HTTP curto pelo túnel, link assinado, sem cabeçalho.

### Gravações do DVR (linha do tempo e reprodução)

Perfil por fabricante como **dado** em `config/device_maps/dvr.yml`
(`Cameras::Playback`): como achar o perfil (`match` no caminho do ponto,
`manufacturers`, ou `address.playback` do aparelho = chave/`off`), o canal
(regex), o caminho RTSP da reprodução (`{channel}`, `{start}`, `{end}` com
`time_format`), `source_suffix` (`#backchannel=0`), `window_s`, a porta HTTP e o
`finder` que lista as gravações. Hoje: Dahua/Intelbras
(`/cam/playback?channel=N&starttime=AAAA_MM_DD_HH_MM_SS&endtime=…`) e Hikvision
(`/Streaming/tracks/N01?starttime=…Z`). Hora = hora local do DVR = fuso do local.

**Aberto/fechado**: fabricante novo = bloco no YAML; se ele lista gravações de
outro jeito, módulo com `find(http, canal, de, até)` em
`Cameras::Timeline::FINDERS` (hoje `dahua_cgi` = `mediaFileFind.cgi`
factory.create → findFile → findNextFile em páginas → close/destroy; `isapi` =
`POST /ISAPI/ContentMgmt/search` em páginas enquanto vier `MORE`). Digest MD5 ou
SHA-256 (`Cameras::Http`, reaproveita o `Isapi.digest`). Nome do evento do DVR →
tipo (motion, person, vehicle, line, region, alarm) no `events` do perfil.

- **Linha do tempo** (`Cameras::Timeline.for(ponto, dia)`): trechos gravados
  (arquivos emendados) e os de evento, com o rótulo traduzido. Cache 2 min (hoje)
  ou 1 h (dias passados); até 90 dias. Erro do DVR (senha, fora do ar) vira
  `error` na resposta, nunca exceção. Web: `GET /cameras/:id/linha-do-tempo`
  (quadro ou `.json`); app: `GET /api/v1/cameras/:id/timeline?day=`.
- **Reprodução** sob demanda, como o `on_demand`: `POST /cameras/:id/reproduzir`
  (`inicio`, `troca`) / `POST /api/v1/cameras/:id/playback` (`start`,
  `replace`) põem no go2rtc o stream `pb_<hex>` com a fonte do perfil e o dono
  (ponto + pessoa) no cache por 2 min, renovado enquanto alguém assiste;
  `DELETE` para; o `Go2rtcSyncJob` tira os `pb_` sem dono. A reprodução toca pelos
  mesmos caminhos do ao vivo com `?pb=` (WebRTC, MSE) ou pelo HLS assinado;
  `?pb=` de outra pessoa ou de outra câmera = 404. Pular ±30 s = nova reprodução
  a partir da posição (início + tempo tocando); velocidade só 1x.

### Tela de Câmeras

- **Web**: menu "Câmeras" (`/cameras`, aparece com alguma câmera visível; local
  pela troca de local da moldura): grade com o ao vivo automático do card
  (`autoplay`, `CameraWidget::AUTOPLAY_MAX`), setas entre os cards e Enter abre.
  `/cameras/:id`: a câmera grande com ← → / PageUp/PageDown / arrastar para
  trocar, F ou o botão para tela cheia, Falar onde o ponto tem `play_media` (e
  quem vê pode comandar), e a linha do tempo (`Ss::StateBandsComponent`; tocar
  na faixa, num evento ou no campo de hora toca dali; ±30 s; voltar ao vivo).
  Controllers `camera-nav` e `camera-playback`.
- **App**: Mais → Câmeras (`/mais/cameras`, `CamerasScreen`): a grade com
  `AutoplayCamera`; tocar abre `CameraViewerScreen` (arrastar troca de câmera,
  tela cheia deitada, `CameraControls` para falar/mover/gravar) e
  `CameraTimelineScreen` (`SsStateBands`, eventos, horário, ±30 s, ao vivo).
  Lista: `GET /api/v1/sites/:id/cameras` (com `features`: live, talk, ptz,
  playback, resolvidos no servidor).

### Limites e o que falta conferir com o DVR de verdade

Tudo conferido só com go2rtc e DVR falsos (WebMock e socket local). Falta ver no
MHDX 3216: o formato exato do `findNextFile` (o `Channel` da resposta é 0-based; o
pedido usa o canal do caminho, 1-based), se o `findFile` sem gravação volta 400
nesse firmware, o tempo de abertura do `cam/playback` no go2rtc 1.9.9 e se o túnel
(`ms-tunel-casa`) repassa o `Upgrade: websocket` (o Action Cable já passa por ele).
Sem áudio no HLS (só vídeo). DVR com relógio fora do fuso do local desloca a
linha do tempo.
