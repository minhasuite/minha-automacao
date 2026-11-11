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
