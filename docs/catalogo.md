# Catálogo de integrações (grupo 9 da paridade com o HA)

As integrações mais instaladas do Home Assistant, como plugins do MA. Todas
entram por `Integrations::PLUGINS`, sem mexer no núcleo.

## Como uma integração do catálogo é feita (`Integrations::SchemaPlugin`)

```ruby
class FooPlugin < SchemaPlugin
  describe key: "foo", title: "Foo", icon: "bolt", description: "…"
  texts en: { title: "Foo", description: "…", fields: { zone: "Zone" } }, es: { … }, "pt-BR" => { fields: { zone: "Zona" } }
  field :host, required: true          # :text (padrão), :number, :url, :select (options:)
  field :zone, :select, options: %w[a b], default: "a"
  field :token, secret: true           # cifrado; vazio no Reconfigurar mantém o guardado

  def self.entries(integration) = [ entry(id: "foo:1", name: "Foo", points: [ point("power", unit: "W"), point("on", "onoff") ]) ]
  def self.read(device) = { "power" => 12.3, "on" => true }  # campo do ponto → valor
  def self.write(point, value) = …                             # ponto gravável
  def self.command(point, command, value) = …                  # opcional: mídia (pause, next…)
end
```

- **Formulário gerado dos campos**: a partial `web/integrations/forms/_schema`
  (só se o plugin não tiver `forms/_<key>` própria). O app recebe a mesma tela
  pelo `/api/v1/screen` (transcodificada), então web e app saem do mesmo schema.
- **O plugin é o driver**: `Drivers.klass` e `Polling.driver_for` perguntam a
  `Integrations.device_driver(kind)` quando o driver não está nos registros
  antigos. Leitura periódica pelo `poll_s` da entrada; comando pelo
  `ExecuteCommandJob` → `write`/`command`.
- **Textos**: rótulo do campo em `fields.<campo>`, dica em `hints.<campo>`,
  opção em `options.<campo>.<opção>`, nome do ponto em `points.<campo>` e nota
  do formulário em `note`. Os comuns (endereço, porta, usuário, senha, token,
  potência, energia, temperatura…) já vêm da base, nos três idiomas.
- **Descoberta**: `mdns`, `ssdp` e `dhcp` como em qualquer plugin; com campo
  `host` e nenhum outro obrigatório, o achado na rede entra sem formulário.
- **Teste**: `spec/services/catalogo_spec.rb` (plugin falso por `stub_const`,
  respostas gravadas com WebMock e aparelhos de mentira em 127.0.0.1) e
  `spec/requests/catalogo_spec.rb` (todo SchemaPlugin aparece no catálogo e o
  formulário sai dos campos).

## Integrações

| Integração | Como fala | O que o dono precisa |
|---|---|---|
| WiZ | UDP 38899 local (`getPilot`/`setPilot`) | só o IP |
| TP-Link Kasa / Tapo | Kasa: TCP 9999 (XOR); Tapo: KLAP v2 no HTTP 80 | Tapo: e-mail e senha da conta TP-Link (o aparelho confere o hash na rede) |
| AdGuard Home | API `/control/*` | usuário e senha do painel |
| Nobreak (NUT) | `upsd` TCP 3493 | usuário/senha do `upsd` se exigir |
| Fully Kiosk Browser | API REST do app (2323) | ligar "Remote Administration" e a senha |
| HomeWizard Energy | API local v1 (`/api/v1/data`, `/state`) | ligar "API local" no app HomeWizard |
| Synology DSM | Web API do DSM (login por chamada, logout no fim) | usuário (de preferência sem admin) e senha; código de 2 etapas se tiver |
| FRITZ!Box Smart Home | AHA (`homeautoswitch.lua`), login PBKDF2/MD5 | usuário e senha do FRITZ!Box |
| Denon / Marantz AVR | HTTP do receiver (`formiPhoneAppDirect.xml`) | só o IP (porta 8080 nos modelos novos) |
| Denon HEOS | CLI HEOS (TCP 1255) | IP de qualquer caixa |
| Sony Bravia TV | REST `/sony/*` com `X-Auth-PSK` | ligar Controle IP com chave pré-compartilhada na TV |
| Clima: Met.no | provedor de `Weather::PROVIDERS` | nada (grátis, sem chave) |
| Clima: OpenWeatherMap | provedor de `Weather::PROVIDERS` (API 2.5 grátis) | chave da conta OpenWeatherMap |
| Forecast.Solar | `api.forecast.solar/estimate` | potência de pico, inclinação e orientação; latitude/longitude do local |
| Electricity Maps (CO2 Signal) | API v3 (`carbon-intensity`, `power-breakdown`) | token grátis em app.electricitymaps.com |
| Lua / Estação do ano | calculadas no servidor | nada |
| Feriados | Nager.Date (`date.nager.at`) | país e, se quiser, o estado |
| Google Tradutor (fala) | provedor de voz `Ai::PROVIDERS` (TTS) | adicionar em Configurações → IA |
| SmartThings | API REST, OAuth do SmartApp do dono; capacidades pelo mapa `config/device_maps/smartthings.yml` | app OAuth (ver abaixo) |
| Netatmo | API Netatmo (estação, homesdata/homestatus, setroomthermpoint) | app em dev.netatmo.com |
| Home Connect (Bosch, Siemens) | API Home Connect | app em developer.home-connect.com |
| Google Nest | Smart Device Management API | Device Access (US$ 5) + cliente OAuth do Google Cloud |
| Ecowitt | o gateway manda para `/mensageiros/<id>` (webhook de integração) | configurar o "Customized upload" no gateway |
| Somfy TaHoma (Overkiz) | local (modo desenvolvedor, token) ou nuvem (login) | token do modo desenvolvedor ou e-mail e senha |
| Ring | API do app (login com 2 etapas; fica só o refresh token) | e-mail, senha e o código que a Ring manda |
| UniFi Network | API da controladora (UniFi OS `/proxy/network` ou a antiga) | usuário local da controladora |
| Speedtest | servidores do Speedtest.net (latência, download 25 MB, upload 5 MB) | nada; mede de hora em hora |
| Impressora (IPP) | Get-Printer-Attributes (IPP binário no HTTP 631) | só o IP |
| InfluxDB | relator do `StateReport` (line protocol, 1.x ou 2.x) | URL, bucket/banco e token ou usuário/senha |
| Modbus TCP | `Modbus` (funções 1, 3, 4, 5 e 6) | os registradores, um por linha |
| Roteador (UPnP/IGD) | `Upnp.soap` no InternetGatewayDevice (SSDP ou endereços comuns) | ligar o UPnP no roteador |
| FRITZ!Box (roteador) | TR-064 (SOAP com digest, porta 49000) | permitir acesso para aplicativos e usuário/senha |
| Music Assistant | API WebSocket (`/ws`, `players/*`, `player_queues/play_media`) | o servidor Music Assistant (app do catálogo ou próprio) |
| Plex Media Server | API do servidor (32400) com `X-Plex-Token` | o token da conta Plex |
| Android TV Remote (Google TV / Android TV) | protocolo do controle do app Google TV (`AndroidTvRemote`): protobuf com tamanho em varint sobre TLS com o certificado do MA; pareamento na 6467, controle na 6466 | o IP e o código de 6 caracteres que a TV mostra no primeiro Continuar |
| OneDrive (cópia de segurança) | destino `Backups::Destinations::Onedrive` (Graph, sessão de upload) | app no Azure (ver abaixo) |

## Nuvem com OAuth: o que o dono cria (`Integrations::OauthPlugin`)

O MA nunca usa um app "do MA" nesses serviços: cada dono cria o próprio app
(client id e secret ficam cifrados na integração). Em todos, o endereço de
retorno é o que aparece no passo "Entrar com …" (`https://<seu endereço>/integracoes/oauth/retorno`,
precisa do acesso remoto com HTTPS ou do IP da rede, conforme o serviço aceitar).

- **SmartThings**: instale a SmartThings CLI (`npm i -g @smartthings/cli`),
  `smartthings apps:create` → tipo *OAuth-In App*, escopos `r:devices:*`,
  `x:devices:*`, `r:locations:*` e o endereço de retorno. A CLI mostra o
  client id e o secret uma vez.
- **Netatmo**: dev.netatmo.com → *My apps* → *Create*; copie client id e
  secret e cadastre o endereço de retorno (*Redirect URI*).
- **Home Connect**: developer.home-connect.com → *Applications* → *Register
  application*, *OAuth Flow: Authorization Code Grant Flow*, endereço de
  retorno. A conta do desenvolvedor precisa ser a mesma do app Home Connect
  (ou acrescente a conta nos *Users* do app).
- **Google Nest**: (1) console.cloud.google.com → projeto → *APIs e serviços*
  → ative *Smart Device Management API* → *Credenciais* → *ID do cliente OAuth*
  (aplicativo da web) com o endereço de retorno; (2) console.nest.google.com/device-access
  → aceite os termos e pague a taxa única (US$ 5) → *Create project* com o
  client id do passo 1; o *Project ID* vai no formulário.
- **OneDrive**: portal.azure.com → *Registros de aplicativo* → *Novo registro*
  (contas pessoais e corporativas), plataforma *Web* com o endereço de retorno,
  *Certificados e segredos* → novo segredo, *Permissões de API* → Microsoft Graph
  delegada `Files.ReadWrite.AppFolder` e `offline_access`. Conectado, vira o
  destino da cópia de fora de casa (a menos que haja `BACKUP_OFFSITE_URL` ou o Google Drive).
- **Ring, Overkiz e os demais** não pedem app: usam a conta do próprio dono
  (Ring guarda só o refresh token; a senha não fica).

## Pareamento com código na tela (`Integrations::PendingPairing`)

Android TV Remote pede um código que só aparece na TV depois que
o MA abre a conexão. O primeiro Continuar abre o pareamento e guarda a
conexão em `PendingPairing` (memória do processo web, 3 min); o segundo
Continuar leva o código e fecha. Outro plugin com o mesmo jeito usa a mesma
espera (`put(id, sessão)` / `take(id)`), sem mexer no núcleo.

- **Android TV Remote**: ligar e desligar vão por WAKEUP/SLEEP (não invertem
  se a TV já estiver no estado); o volume é lido (nível/máximo da TV) e sobe
  e desce por tecla; o app aberto vem da TV. `play_media` abre um link (ex.:
  `https://www.netflix.com/title/…` ou `market://launch?id=<pacote>`).
