# Aplicativos (F8g)

Serviços extras que rodam no servidor local para a instalação inteira (os
"Apps"/add-ons do HAOS). Tela: **Configurações → Aplicativos** (só o Dono):
instalados, **Loja de aplicativos** e a página do app (Informações,
Configuração, Log, Desinstalar).

## Como funciona

```
navegador → Rails (Web::AppsController, papel Dono, AuditEvent "app.*")
          → Apps::Supervisor (HTTP + SUPERVISOR_TOKEN, rede interna do compose)
          → supervisor/server.rb (único com /var/run/docker.sock)
          → Docker (containers ma-app-<chave>, label minha-automacao.app)
```

- **Rails nunca fala com o Docker.** Só o serviço `supervisor` do
  `docker-compose.local.yml` monta o socket. Ele roda na imagem do próprio app
  (Ruby + puma já instalados, sem imagem nova), ouve em `:8099` só na rede
  interna (sem porta no host) e exige `Authorization: Bearer
  $SUPERVISOR_TOKEN` (gerado pelo `bin/deploy-local` no `.env`, 64 hex). Não
  recebe o `.env` do Rails: só o token e os segredos que um manifesto pode
  repassar (`AppCatalog::SERVER_ENV`).
- **Só apps do catálogo.** Imagem, versão, portas, volumes, rede, devices,
  shm e saúde vêm do manifesto, que está na imagem (não é editável pela web).
  Do pedido só entram as opções do schema (`Manifest#clean_options`): tipo,
  padrão, faixa, lista e expressão. Nada de `privileged`, `network_mode: host`,
  bind de pasta do host ou device fora de `/dev/serial/by-id/…`/`/dev/ttyUSB*`/
  `/dev/ttyACM*`.
- **Só containers com o label** `minha-automacao.app=<chave>` (nome
  `ma-app-<chave>`, volumes `ma-app-<chave>-<nome>` com o mesmo label). Os
  apps ficam fora do projeto do compose: o deploy não os derruba.
- **Apps do sistema** (`system: <serviço do compose>`: Mosquitto e go2rtc):
  achados pelos labels do compose do projeto `minha-automacao`; só status,
  log e reiniciar. Não se instalam, param nem desinstalam por aqui.
- **Instalar, reconfigurar e atualizar** rodam em segundo plano no
  supervisor (puxar a imagem demora); a página mostra "Instalando…" e se
  recarrega. Falha fica em "Última operação falhou".
- **Iniciar com o servidor / watchdog** viram a política de reinício do
  Docker: com o servidor = `unless-stopped` (também volta se cair); só
  watchdog = `on-failure`; nenhum = `no`. O supervisor ainda reinicia, a cada
  30 s, app com política e saúde `unhealthy` (o Docker não faz isso sozinho).
- **Abrir interface**: o app publica a porta do manifesto (`web_ui.port`) na
  rede de casa e o Rails só checa o papel, audita e redireciona para
  `http://<IP do servidor>:<porta>`. O proxy pelo Rails ficou de fora porque
  as interfaces (Uptime Kuma, Node-RED, Z2M) dependem de websocket e de
  caminho na raiz. Limites: não abre pelo acesso externo (túnel) e, na rede
  de casa, a porta não passa pelo login do Minha Automação, só pelo do app.
- **Atualização**: a versão instalada fica no label; quando o catálogo traz
  outra, a tela mostra "Atualização disponível" e o botão Atualizar (puxa a
  versão nova e recria o container com as mesmas opções e volumes).
- **Desinstalar** remove o container; sem "manter os dados" remove também os
  volumes do app.
- Na **VPS** não há supervisor (`SUPERVISOR_URL` vazio): a tela mostra só o
  catálogo com o aviso "Disponível no servidor local".

## Adicionar um app ao catálogo

1. Crie `config/apps/<chave>.yml` (chave = `[a-z0-9_]`, nome do arquivo):

```yaml
name: Uptime Kuma
category: Monitoramento        # agrupa na loja
icon: chart-bar                # um .svg de app/assets/images/icons
description: Vigia sites e serviços e avisa quando algo cai.
image: louislam/uptime-kuma    # imagem oficial
version: "1.23.16"             # tag FIXA, entre aspas (nunca latest)
network: bridge                # bridge (isolado) ou apps (alcança o mosquitto)
ports:                         # host 1024-65535, fora das reservadas, única no catálogo
  - { container: 3001, host: 3001 }
volumes:                       # viram volumes ma-app-<chave>-<nome>
  - { name: data, path: /app/data }
web_ui: { port: 3001 }         # opcional: porta do host com a interface
env: { TZ: America/Sao_Paulo } # fixo
server_env:                    # opcional: VAR do app ← segredo do servidor (lista SERVER_ENV)
  APP_MQTT_PASSWORD: MQTT_PASSWORD
health: { test: ["CMD", "curl", "-f", "http://localhost:3001"] } # opcional
shm_mb: 256                    # opcional (64-2048)
options:                       # formulário gerado; só valores, nunca estrutura
  - key: tz
    label: Fuso horário
    type: string               # string | integer | boolean | enum | device
    env: TZ                    # obrigatório, menos em device
    default: America/Sao_Paulo
    pattern: '\A[A-Za-z_/]+\z' # string: opcional; integer: min/max; enum: choices
    required: false
    secret: false              # true = senha: não volta para a tela nem para o label
    help: Texto curto abaixo do campo.
  # - { key: usb, label: Coordenador, type: device, path: /dev/zigbee, required: true }
```

Campos opcionais que pedem decisão de segurança (já validados no
`AppCatalog`; app de terceiro não pode usar `cap_add`, `sysctls`, `connect`
nem porta baixa):

```yaml
command: ["serve"]             # argumentos do container (lista, sem shell)
cap_add: [NET_ADMIN]           # só AppCatalog::CAPS (hoje NET_ADMIN, para o wg-easy)
sysctls:                       # só AppCatalog::SYSCTLS (rede, valem no namespace do container)
  net.ipv4.ip_forward: "1"
ram_mb: 2048                   # memória estimada; >= 1024 = "Pesado" na loja e aviso na página
connect:                       # botão "Conectar" (página do app, com o app rodando)
  integration: adguard         # plugin de Integrations::PLUGINS → formulário já preenchido
  port: "3080"                 #   (os outros valores viram campos; {host} = IP do servidor)
# ou: { ai: ollama, base_url: "http://{host}:11434", model: "qwen2.5:1.5b" }
#   → cria/atualiza a conta em Configurações → IA e chama `prepare` do provedor pela fila (AiPrepareJob)
```

Porta do host abaixo de 1024 só a de `AppCatalog::LOW_PORTS` (53, o DNS do
AdGuard). A unicidade das portas é por porta **e** protocolo (Syncthing usa
22000 tcp e udp). As portas dos serviços do compose na rede do host (5353,
5540, 5580, 8081, 51826) estão em `RESERVED_PORTS`.

**Conectar**: o IP do servidor é o do endereço aberto (se for IP) ou o
`APP_HOST`; entra na Saída HTTP (`http_allow`) porque o Rails fala com o app
pela porta publicada no IP do servidor (o web e o worker não estão na rede
`minha-automacao-apps`; os apps que precisam um do outro, como Grafana →
InfluxDB e Double Take → CompreFace, ficam nela e se acham por
`ma-app-<chave>`). Vira `AuditEvent` `app.connect`.

2. Rode `bundle exec rspec spec/services/app_catalog_spec.rb`: o spec carrega
   todos os manifestos (campo desconhecido, tag `latest`, porta reservada ou
   repetida, ícone que não existe e segredo fora da lista quebram).
3. Confira a tag: `docker manifest inspect <imagem>:<versão>`.
4. Commit + deploy. O app aparece na loja; nenhuma linha de código muda.

Para **atualizar a versão** de um app, troque só `version`. Campo novo no
manifesto (por exemplo `cap_add`) é decisão de segurança: entra em
`AppCatalog::KEYS`, na validação e no `container_body`, com spec.

## Catálogo inicial

| App | Rede | Porta | Observação |
|---|---|---|---|
| Mosquitto, go2rtc | compose | – | do sistema |
| Zigbee2MQTT | apps | 8080 | opção do coordenador USB; instalar quando ele chegar |
| Node-RED | apps | 1880 | |
| ESPHome | bridge | 6052 | sem mDNS (não roda na rede do host) |
| Frigate | apps | 8971 | detector na CPU, sem Coral/GPU |
| Music Assistant | bridge | 8095 | sem descoberta de aparelhos (não roda na rede do host) |
| Editor de arquivos (code-server) | bridge | 8443 | edita só a própria pasta |
| Uptime Kuma | bridge | 3001 | |
| AdGuard Home | bridge | 53 tcp/udp, 3080 | ~128 MB; Conectar → integração AdGuard |
| Speedtest Tracker | bridge | 8765 | ~256 MB; chave `APP_KEY` obrigatória; Conectar → integração Speedtest Tracker |
| Vaultwarden | bridge | 8222 | ~64 MB; cofre web só por HTTPS |
| Syncthing | bridge | 8384, 22000 tcp/udp, 21027 udp | ~128 MB |
| WireGuard (wg-easy) | bridge | 51820 udp, 51821 | ~64 MB; NET_ADMIN + sysctls de encaminhamento |
| Whisper / Piper (Wyoming) | bridge | 10300 / 10200 | ~1 GB / ~256 MB; voz pt-BR; Conectar → provedor `wyoming` |
| Ollama | bridge | 11434 | **~2 GB**; Conectar → provedor `ollama` e baixa o modelo |
| CompreFace | apps | 8000 | **~3 GB, CPU com AVX** |
| Double Take | apps | 3005 | ~256 MB; Conectar → integração Double Take |
| OwnTracks Recorder | bridge | 8083 | ~64 MB; modo HTTP, sem senha própria |
| ESPresense Companion | apps | 8267 | ~256 MB; Conectar → integração ESPresense |
| Scrypted | bridge | 10443, 11080 | **~1 GB**; sem mDNS |
| InfluxDB | apps | 8086 | ~512 MB; nasce com org `casa` e bucket `minha_automacao` |
| Grafana | apps | 3002 | ~256 MB; Conectar → fonte de dados + painel inicial |
| ntfy | bridge | 8093 | ~64 MB; Conectar → canal de aviso |

### Notas por app (ondas, 11/2026)

- **AdGuard Home**: no assistente inicial deixe a interface na porta 3000
  (é a publicada como 3080). DNS na 53 do host: se o Debian tiver o
  `systemd-resolved` com o stub na 53, desligue o `DNSStubListener` antes. Na
  rede bridge todas as consultas aparecem vindas do gateway do Docker (sem
  estatística por aparelho). "Pausar por automação": o ponto "Proteção"
  (onoff) da integração AdGuard.
- **Vaultwarden**: o cofre web exige contexto seguro (HTTPS). Use pelo acesso
  externo (túnel) e preencha "Endereço HTTPS do cofre"; desligue "Permitir
  criar contas" depois de criar as da casa.
- **Syncthing como destino de backup**: o supervisor não monta pasta do host,
  então o Syncthing do servidor não enxerga `/opt/minha-automacao/backups`.
  O caminho seguro é o inverso: a cópia fora de casa (`docs/backup.md`) já sai
  **cifrada** por SSH para uma máquina com Syncthing (NAS, PC da outra casa),
  e o Syncthing replica essa pasta para outros lugares. O Syncthing do
  catálogo serve para receber pastas de outros aparelhos (fotos, documentos)
  e para guardar cópias que outros servidores mandam.
- **WireGuard (wg-easy)**: pede `NET_ADMIN` (criar a interface wg0) e os
  sysctls `net.ipv4.ip_forward`/`src_valid_mark`; nada de `SYS_MODULE` (o
  kernel do Debian carrega o módulo sozinho). Abra a UDP 51820 no roteador
  para o IP do servidor. A interface (51821) roda sem HTTPS (`INSECURE=true`):
  só na rede de casa. IPv6 desligado (`DISABLE_IPV6`).
- **Whisper/Piper**: argumentos fixos para pt-BR (`small-int8 --language pt`,
  voz `pt_BR-faber-medium`). O motor `wyoming` do Assistente de voz também
  pode usar `tcp://IP:10300/10200`.
- **Ollama**: modelo pequeno (padrão `qwen2.5:1.5b`; `llama3.2:1b` também
  serve); sem GPU é lento. O Conectar baixa o modelo (`/api/pull`, até 30 min).
- **Double Take + CompreFace**: no CompreFace crie um serviço de
  reconhecimento; no editor do Double Take configure `mqtt.host: mosquitto`
  (usuário `automacao`, senha do `MQTT_PASSWORD` do `.env`), `frigate.url`
  e `detectors.compreface.url: http://ma-app-compreface` com a chave.
- **OwnTracks Recorder**: modo HTTP (`OTR_PORT=0`, sem MQTT); no app do
  celular, modo HTTP com `http://IP:8083/pub?u=<pessoa>&d=<aparelho>`. Não tem
  senha: só na rede de casa ou pela VPN (wg-easy).
- **ESPresense Companion**: no `config.yaml` do volume, `mqtt.host: mosquitto`
  e usuário `automacao`. O Minha Automação lê tanto o cômodo do Companion
  quanto as distâncias cruas das placas.
- **Scrypted**: sem mDNS, o HomeKit pode precisar do pareamento manual. As
  câmeras entram direto no Scrypted (RTSP/ONVIF); o RTSP do go2rtc (8554) não
  é publicado no host de propósito.
- **Grafana + InfluxDB**: instale o InfluxDB (token de administrador
  gerado por você), conecte (integração InfluxDB: exporta em lote), instale o
  Grafana e conecte (token do InfluxDB no formulário).

### Dozzle (fora do catálogo, de propósito)

O Dozzle precisa do socket do Docker. Montar o socket, mesmo "só leitura"
(`:ro` vale para o arquivo, não para a API), dá a um container de terceiro
controle total do host (criar container privilegiado, ler segredos de
todos). Só o supervisor monta o socket, e o catálogo não tem campo para bind
de caminho do host. Os logs já estão na tela: **Configurações → Logs**
(serviços do compose, pelo supervisor) e a aba **Log** de cada app.

## Operação no servidor

```bash
docker ps --filter label=minha-automacao.app            # apps instalados
docker compose logs --tail 50 supervisor               # ações e watchdog
```

Se o supervisor cair, a tela mostra "Supervisor dos aplicativos fora do ar";
os apps continuam rodando (são containers independentes).
