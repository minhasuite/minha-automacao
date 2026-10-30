# Câmeras

Toda câmera é um aparelho `go2rtc` com um ponto `stream` por vídeo (perfil
ou canal). O vídeo nunca vai direto do navegador para a câmera: o
`Go2rtcSyncJob` (a cada minuto) põe um stream por ponto no go2rtc do
servidor (nome = id do ponto) e a tela pede ao Rails o quadro
(`GET /cameras/:id/quadro`) e o ao vivo por WebRTC
(`POST /cameras/:id/ao-vivo`), com o papel no local. Sem `GO2RTC_URL` (VPS)
o widget mostra "Sem conexão".

## De onde vem a câmera (plugins de integração)

| Plugin | Para quê | Aparelho |
| --- | --- | --- |
| `CameraPlugin` "Câmera RTSP / ONVIF" | qualquer câmera IP | um `go2rtc`; RTSP = um ponto; ONVIF = um ponto por perfil + `motion` se houver eventos |
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
