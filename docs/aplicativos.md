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

## Operação no servidor

```bash
docker ps --filter label=minha-automacao.app            # apps instalados
docker compose logs --tail 50 supervisor               # ações e watchdog
```

Se o supervisor cair, a tela mostra "Supervisor dos aplicativos fora do ar";
os apps continuam rodando (são containers independentes).
