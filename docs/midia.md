# Mídia (ondaC2)

Local → **Mídia** (`/locais/:id/midia`; no app, Mais → Mídia, pela tela do
servidor): os players com o que está tocando e controles, grupo de caixas,
"Falar num player" e as bibliotecas (fontes) com "Tocar em…".

## Players

Player = todo ponto que aceita `play_media` (`Notifier::Channels::Player.players`):

| Driver | Tocar endereço | Observação |
| --- | --- | --- |
| `cast` (Chromecast) | Default Media Receiver | tipo pelo final do endereço (`Cast::TYPES`) |
| `sonos` | AVTransport | favoritos como biblioteca; grupo nativo `join`/`unjoin` |
| `dlna` (novo, `DlnaPlugin`) | AVTransport com DIDL | qualquer TV/caixa/receiver DLNA; achado por SSDP (MediaRenderer) |
| `webos`, `tizen` | abre no navegador da TV | a TV Samsung/LG também é DLNA: prefira o `dlna` para áudio e vídeo |
| `adb` (Android TV) | intent VIEW | — |
| `spotify` | URI/playlist/busca do Spotify | — |
| câmera (`go2rtc`) com alto-falante | go2rtc toca no alto-falante | ver `docs/cameras.md` |
| helper **Grupo** de players | repassa a cada membro | o valor é o do membro que estiver tocando |

Comandos da capacidade `media`: os de antes + `join` (valor = id do ponto
`media` que coordena) e `unjoin`. O aparelho limita por `address.supports`.

## Falar (TTS) em qualquer player

Canal de fala `player:<id do ponto>` (`Notifier::Channels::Player`): a ação
"Falar", os avisos e a tela usam a voz da instalação (`Ai::Audio.speak`), o
áudio vira anexo assinado de 1 dia e o player toca. O player precisa alcançar
o servidor: `MEDIA_PUBLIC_URL` (ou `ASSIST_MEDIA_URL`, ou `http://APP_HOST`).

## Fontes (navegador de mídia)

Registro `MediaSources::PLUGINS`; fonte nova = subclasse de
`MediaSources::Source` com `describe`, `browse(site, path, query:)` → `Page`
(título, volta, itens) e `media_url(site, id)` (+ `preview_url`,
`player_ids`, `searchable?`, `uploads?`). Spec com fonte falsa em
`spec/services/onda_c2_spec.rb` e `spec/requests/onda_c2_spec.rb`.

| Fonte | O quê |
| --- | --- |
| `local` Arquivos de mídia | pasta `MEDIA_DIR/<local>` (padrão `storage/media`): pastas, enviar (até 1 GB, áudio/vídeo/imagem), apagar |
| `radios` Rádios | radio-browser.info: mais votadas, do país do local, por gênero, busca |
| `dlna` Servidores DLNA | NAS, Plex, Jellyfin, minidlna da rede (SSDP + ContentDirectory) |
| `players` Bibliotecas dos players | driver com `browse(device, path)` (hoje: favoritos do Sonos); toca só no próprio player |
| `recordings` Gravações das câmeras | câmera → dia → trechos |

Arquivo local e gravação chegam ao player por link assinado de 12 h
(`/midia/arquivo/<nome>?t=…`, `Web::MediaFilesController`, sem sessão, com
Range); o link só abre arquivo dentro da raiz da fonte.
