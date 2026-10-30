# minha-automacao — guia rápido

Monolito Rails 8.1: web (Hotwire) **e** API `/api/v1` do app Flutter
`minha-automacao-app`, no mesmo processo. É o servidor de automação da
MinhaSuite (casa, loja e fábrica), no lugar do Home Assistant. Roda inteiro
num servidor local (Linux com Docker, túnel Cloudflare para fora); não há
central/borda nem `EDGE=1`. A VPS (`minhaautomacao.minhasuite.com`) serve só
para validar UI/UX. Produto em
`../docs/PROPOSTA.md`; modelo de dados, DSL, API e decisões em
`../docs/ESQUEMA-V1.md`; stack em `docs/adr/0001-stack.md`. O padrão da suíte
está na skill `padrao-suite`; aqui só o que é deste repo.

**Estado:** base da suíte (empresa, usuários, auth da API, convites, push,
notificações, assinatura, IA, licenças, telemetria, páginas legais e conta) +
**F1**: locais, áreas, papéis por local, dispositivos, pontos, etiquetas (só
modelo), na web (`/locais`) e na API + **F2**: comandos rastreados
(`Command`, `Points::Command` → `ExecuteCommandJob` → `Drivers.for`),
histórico (`readings` particionada, `reading_rollups`, `events`), tempo real
(Solid Cable, `PointsChannel`) e página do ponto com gráfico + **F3**: driver
`tuya_local` (3.1/3.3/3.4/3.5), ouvinte persistente, importação do LocalTuya
e o servidor local da casa (`docker-compose.local.yml`, `bin/deploy-local`) +
**F4**: primitivas declarativas (`pulse_ms`/`max_on_s`, `PointLink`,
`Schedule`, `Scene`, `NotifyRule`, `AlertRule`/`Alert`) na web (página do
ponto, `/locais/:id/automacao`, `/alertas`) e na API +
**F5**: dashboards dirigidos pelo servidor (`Dashboard`, versões, automático,
editor web, widgets ao vivo, API; formato em `docs/dashboards.md`) no Início +
**F6**: automações com a DSL JSON (`Automation`, versões, `AutomationRun` com
trace, simulação, editor de blocos em `/locais/:id/automacoes`, API e webhook;
referência em `docs/automacoes.md`) + **F8 (1ª metade)**: drivers `mqtt`
(Mosquitto, ouvinte, descoberta do zigbee2mqtt) e `go2rtc` (câmeras, widget
`camera` com quadro e ao vivo por WebRTC passando pelo Rails) + **F8 (2ª metade)**:
`integrations` (conta da Alexa), drivers `xiaomi_miot` (robô por miIO local,
widget `vacuum`) e `alexa` (anúncio/fala, canal `alexa:<ponto>` nos avisos). + **F8c**:
integrações de conta como plugins (`Integrations::Plugin`, catálogo, assistente,
varredura e adoção; Tuya/Smart Life por QR, Xiaomi, Alexa, DVR Hikvision,
MQTT/Zigbee2MQTT, importar do HA) e a lista de dispositivos do local
(`docs/integracoes.md`) + **F8d**: Configurações, pessoas, chaves e visões
dos painéis + **F8e**: helpers como plugins (`HelperTypes`, aba "Helpers"
do local; `docs/helpers.md`) + **F8f**: gatilhos, condições e ações da DSL
como plugins, seção "Automações e cenas" (Automações · Cenas · Scripts ·
Blueprints · Regras simples), scripts com campos, cenas com captura e
blueprints com importação do HA (`docs/scripts.md`, `docs/blueprints.md`).

## Rodar

```bash
docker compose -f .devcontainer/docker-compose.yml up -d     # pg 127.0.0.1:6299, app :4121
docker compose -f .devcontainer/docker-compose.yml exec -T app bash -c \
  'cd /app && bundle exec rspec && bundle exec rubocop --parallel && bundle exec brakeman -q'
```

`bash -c`, não `bash -lc`. Detalhes em `docs/DEV_ENV.md`. Seeds:
`bin/rails db:seed` (matriz de IA, flags e, só em dev, `teste@teste.com` /
`12345678`). Web: `bin/rails tailwindcss:build` antes de abrir a tela ou
rodar spec que renderiza layout. Cobertura mínima 90%.

## Decisões que não se deduzem do código

- **Papéis** (`User::ROLES`): `owner` (Dono: tudo, inclusive plano, chaves de
  integração, zerar e convidar administrador), `admin` (Administrador:
  convida membro, vê os avisos da empresa, usa a IA), `member` (Membro).
  Dono e administrador da empresa são `owner` em todos os locais.
- **Papel por local** (`SiteMembership::ROLES`, crescente): guest < operator <
  resident < technician < owner. Ver: qualquer; cadastro: technician+; local e
  membros: owner; comando conforme o risco do ponto (normal guest+, sensitive
  operator+, critical resident+). Sem papel = 404. Mesma regra na web e na API
  (`SiteAuthorization`). `expires_at` vencido = sem acesso; `area_ids` ainda
  não restringe nada.
- **Pontos**: `key` única no local (gerada `dispositivo.ponto`); `options` é
  lista de rótulos; os filhos do local caem por cascade no banco (sem
  `dependent:`). `devices.driver` fica no dispositivo até as integrações (F3).
- **Sem "empresa" na tela (F8d)**: o tenant continua por dentro
  (`acts_as_tenant`), mas a interface fala em "instalação". Não existe mais
  entrar em outra empresa (`Companies::Join` e `company/join` saíram).
- **Configurações (F8d)**: `/configuracoes/{paineis,pessoas,chaves,sistema,conta}`
  com subnavegação (`web/settings/_frame`). Pessoas: o dono cria a conta
  (e-mail + senha inicial) ou gera um **link de convite** de uso único, 7 dias
  (`Invite.generate!` → token em claro só na resposta; `/convite/:token`
  público cria a conta na instalação com `site_id`/`site_role`). Pessoa
  desativada (`users.disabled_at`) não entra na web, na API nem por chave; o
  dono não se desativa nem se remove. Link e chave aparecem só na resposta
  (form com `turbo: false`), nunca em flash.
- **Chave de integração** (`ServiceApiKey`): `site_ids` (obrigatório) +
  `scopes` read/command/write. Controller da API libera ação para chave só via
  `key_actions` ({ação → permissão}); `authorize_site!` da API dá 404 em local
  fora da chave e `visible_sites` filtra listas. `POST /points/:id/value` só
  em ponto de dispositivo `virtual`.
- **Zerar / exportar / excluir**: tabela nova do domínio entra em
  `Accounts::WipeData::MODELS` (filhos antes dos pais) e em
  `Accounts::ExportData`. `AiUsage` não zera (senão zeraria a cota).
- **Notificação** com `user` vai só para a pessoa; sem `user`, para dono e
  administradores (`Notification.for_user`, `SendPushJob`). Crie pelo
  `Notifier.notify!` (push + `dedup_key`).
- **IA**: features em `AiPlanFeature::FEATURES` (`ask`, `daily_summary` são
  placeholders). Grátis não tem IA; Pro no tier light, Max no standard.
  Feature nova = entrada em `DEFAULTS` (a lista entra na chave do cache).
- **Credencial vazia = feature desligada:** IA, Google, FCM, R2, meulog, SMTP,
  licenças.
- **Licenciamento central** (`Licencas::*`, contrato em
  `../../licencas-workspace/licencas/docs/INTEGRACAO.md`): o `recompute!`
  informa as assinaturas, a exclusão da empresa apaga o dono lá e a venda pela
  web vira `source/plan_provider: licencas`. `LicencasEnviarTudoJob` (e a rake
  `licencas:enviar_tudo`) reenvia tudo todo dia às 4h.
- `encrypts` exige `AR_ENCRYPTION_*` em produção (dev/teste derivam do
  `secret_key_base`).
- **Comandos (F2)**: `Points::Command.call(point, cmd, value, source:)` valida
  (422 antes de criar), cria o `Command` e roda o `ExecuteCommandJob`: na hora
  no driver `virtual`, na fila nos outros. API responde **202** com o
  comando. Status `pending → sent → confirmed | failed | expired` (na fila há
  mais de `Command::TTL` = expira, não executa). Driver novo = classe com
  `execute(point, command, value)` em `Drivers::REGISTRY`.
- **Valor novo de ponto só por `Point#report!`**: grava o ponto, a leitura
  (`history`/`deadband`/`interval`), o evento de qualidade e faz
  `broadcast_refresh_to(point)`. Comando não vira AuditEvent (a tabela
  `commands` é a trilha); cadastro e papel por local viram.
- **Histórico**: `readings` particionada por mês em UTC (`readings_AAAA_MM` +
  `readings_default`), por isso o banco é `db/structure.sql` (não schema.rb).
  `ReadingsMaintenanceJob` (3h) cria a do mês seguinte e aplica retenção (cru
  365 dias ou `retention_days`; comandos e eventos 365). `RollupReadingsJob`
  (hora em hora, :05) refaz as 3 últimas horas e os dias delas (dia de SP).
- **Tempo real**: Solid Cable no banco primário. Tela com ponto usa
  `turbo_stream_from point, channel: PointsChannel` (exige papel no local) e a
  mudança chega como *refresh* com morph: cada tela recarrega com o próprio
  papel do usuário.

- **Tuya local (F3)**: `Tuya::Protocol` (quadros, sem rede) → `Tuya::Connection`
  (TCP 6668, sessão 3.4/3.5) → `Drivers::TuyaLocal`. Dispositivo: `address`
  `{host, version, port}`, `external_id` = device_id, `credential` = local_key
  (`encrypts`); ponto: `address` `{"dps" => "1"}`, número = bruto × `scale` +
  `offset`. Sem tabela `integrations` (nada é compartilhado entre aparelhos;
  entra com o primeiro driver de conta). Importação:
  `rake 'tuya:importar[arquivo.json,Casa]'` (JSON de `core.config_entries` →
  `data.devices` do LocalTuya; área "Importados do HA"; idempotente por
  device_id; nome com portão/sirene vira risco crítico).
- **Ouvinte Tuya (`devices.listen`) fica DESLIGADO por padrão até a migração
  (F10)**: o LocalTuya do HA está conectado nos mesmos aparelhos e muitos
  aceitam uma conexão só. Ligue só para teste e desligue no fim. Ele roda no
  processo worker (`SolidQueue.on_worker_start`, `TUYA_LISTENER=off`
  desliga), uma thread por aparelho, heartbeat 10 s, reconexão até 60 s; caiu
  = pontos `unavailable`. Com ele ligado o comando sai pela conexão aberta.
  Sem `listen`, o comando abre uma conexão curta (set + status). Exige um
  processo worker só (`JOB_CONCURRENCY=1`).
- **Primitivas (F4)**: `Point#report!` com valor novo chama
  `Automations.on_change` (auto-off, espelhamento, aviso, alerta; erro numa
  não para as outras; corrente síncrona até `MAX_DEPTH`). Valor que volta com
  a conexão (qualidade anterior ≠ good) não espelha nem avisa. Todo tempo
  (pulso, `max_on_s`, `for_s` do alerta, etapas) é job agendado no Solid Queue
  com carimbo (`changed_at`/`level`): sobrevive a reinício e job velho não age;
  agendas são `next_run_at` no banco + `RunSchedulesJob` a cada minuto
  (atrasada > 5 min é pulada). Espelhamento: sem ciclo além do par
  bidirecional (validação), não comanda destino já no valor, anti-eco por
  `commands.origin_point_id` (15 s). Comando de automação: `source:
  "automation"`, sem usuário. Canais: `Notifier.deliver!` (in_app + push);
  `alexa` entra lá na F8. Avisos e alertas vão para dono/administradores.
  "Ciente" (operator+) para o escalonamento; o alerta fecha quando a condição
  some (`auto_resolve`) ou no ciente (sem `auto_resolve`).
- **Dashboards (F5)**: JSON da §6 validado por `Dashboards::Schema` (à mão;
  tipo novo = entrada em `WIDGETS` + partial `web/dashboards/widgets/_<tipo>` +
  dado no `Resolver`). `definition` = publicada, `draft` = rascunho; publicar e
  voltar versão gravam `dashboard_versions`. Local sem dashboard ganha o
  automático (`auto`, regenerado a cada leitura até a primeira publicação).
  Tempo real: `Point#report!` manda `point_changed` (só o id) no stream
  `[site, :points]`; a tela recarrega os `turbo-frame[data-points~=id]` em
  `/paineis/:id/w/:widget_id` com o papel de quem vê. Widget nunca comanda
  direto: o botão vai para `PointsController#command` (papel x risco) e volta
  ao quadro. Painel padrão da pessoa em `users.dashboard_prefs`.
- **Automações da DSL (F6)**: `definition` = publicada (roda), `draft` =
  rascunho do editor (pode ficar incompleto; a DSL é validada na
  publicação). Ações viram programa plano (`Engine#compile`); espera grava
  `pc`/variáveis em `automation_runs.state` e agenda `AutomationResumeJob`
  com `seq` (job velho não retoma). Gatilhos de ponto vêm do
  `Automations.on_change` (mesma regra de "valor que voltou com a conexão não
  dispara"); horário/sol pelo `RunSchedulesJob` a cada minuto. Laço: causa =
  execução na thread ou comando com `automation_run_id` no ponto há < 10 s;
  própria automação ou corrente > 3 = "laço evitado". Comando sempre por
  `Points::Command` (`run:`), nunca direto no driver. Notificação `kind:
  "automacao"`. No Dell nenhuma automação ativa sobre aparelho real até a F10.
- **Gatilho, condição ou ação nova (F8f)**: cada tipo é um plugin
  (`Automations::Block`) registrado em `Automations::TriggerTypes::PLUGINS`,
  `ConditionTypes::PLUGINS` ou `ActionTypes::PLUGINS`; **nada de `case` por
  tipo** no motor, no disparo, na validação ou no editor (eles perguntam ao
  plugin). Tipo novo = classe (`describe key:, label:, fields:, defaults:`,
  `rules`, e `fires_on_change?`/`holds?`/`clock`+`due?` no gatilho,
  `check(ev, c)` na condição, `call(engine, path, node)` [+ `compile`,
  `commanded_point_ids`] na ação) + nome em `PLUGINS` + spec. Passo a passo
  em `docs/automacoes.md`. Tipo de campo novo é que mexe no `Validator`, no
  `Editor#cast` e em `web/automations/_field`.
- **Scripts (F8f)**: `Automation` de `kind: "script"` (`site.scripts`;
  `site.automations` só traz `kind: "automation"`): só ações, `fields`
  (campos tipados; `$nome` = ponto do campo), mesmas versões/modos/trace.
  Cada script tem um ponto de capacidade `script` (comando `run`) no
  dispositivo virtual "Scripts" (`Scripts`, fora da lista de dispositivos):
  é o botão do painel e o que a Alexa (F9) vai expor. Ação `script` chama
  com campos (execução própria, `cause_run`, laço barrado). API
  `/api/v1/scripts` (`run` exige o papel do risco dos pontos do script e dos
  campos; chave com `command`).
- **Blueprints (F8f)**: `Blueprint` (inputs tipados + DSL com
  `{"!input": k}`); prontos em `config/blueprints/*.json`
  (`Blueprints.sync_builtin!`), importados do HA por
  `Blueprints::HaImport` (o que não converte vai para `unsupported` e
  aparece na tela). Mudar inputs/definition/mode sobe a versão e refaz só o
  **rascunho** das automações ligadas (aviso no editor). Criar por blueprint
  com ponto crítico fica no rascunho.
- **Cenas (F8f)**: "Capturar estado agora" (`Scene.capture`) só lê; modo ao
  vivo (aplicar ao salvar) desligado por padrão. Nunca acione cena real de
  teste.
- **MQTT (F8)**: `Drivers::Mqtt` (endereço do ponto `{topic, json_path,
  command_topic, payload_on, payload_off}`; número com `scale`/`offset` via
  `Point#from_raw`/`to_raw`) e `Mqtt::Listener` no worker (só com `MQTT_URL`;
  assina os tópicos dos pontos a cada 30 s, caiu = pontos `unavailable`,
  reconexão até 60 s). Comando só publica; o eco do estado atualiza o ponto.
  Broker e senha são do servidor (`.env`), por isso não há tabela
  `integrations`: credencial de aparelho continua em `devices.credential`.
- **zigbee2mqtt (F8)**: serviço no perfil `zigbee`, desligado até o
  coordenador USB chegar. Descoberta: `zigbee2mqtt/bridge/devices` (retido) →
  `Mqtt::Z2m.discover!` (dispositivo por `ieee_address`, ponto pela
  propriedade, chave `nome_z2m.propriedade`; exposes binário/numérico/enum/
  texto → onoff, contato, movimento, problema, medição, dimmer, setpoint,
  enum, evento). Local: `Z2M_SITE_ID` ou o único local do servidor.
  **Para ligar:** no Dell, `ls /dev/serial/by-id/`; no `.env`,
  `ZIGBEE_DEVICE=/dev/serial/by-id/usb-...` e `ZIGBEE_ADAPTER=` (`ember` para
  Sonoff ZBDongle-E/EFR32, `zstack` para ZBDongle-P/CC2652); `bin/deploy-local`
  liga o perfil sozinho. Frontend do z2m em `:8080` com
  `Z2M_FRONTEND_TOKEN` do `.env`. Parear com `permit_join` pelo frontend.
- **Câmeras (F8)**: dispositivo `go2rtc` (`address` {host, port, username},
  `credential` = senha) e um ponto `stream` por canal (`address` {path};
  use o substream e RTSP/TCP, padrão do go2rtc: o DVR Hikvision entrega H.264
  quebrado no main). O go2rtc sobe sem config; `Go2rtcSyncJob` (a cada minuto)
  põe os streams pela API (nome = id do ponto). Usuário sem senha fica de fora
  (o DVR bloqueia com senha errada). O navegador só fala com o Rails:
  `GET /cameras/:id/quadro` (JPEG, último guardado em `tmp/snapshots`, 3 s de
  reaproveitamento, nada no histórico) e `POST /cameras/:id/ao-vivo` (oferta
  SDP → go2rtc → resposta), qualquer papel no local. Mídia WebRTC na 8555
  (tcp/udp) anunciada em `APP_HOST`. Sem `GO2RTC_URL` (VPS) o widget mostra
  "Sem conexão". Importação: `... | rake 'go2rtc:importar[Casa]'` com o JSON
  na entrada padrão (senha nunca em arquivo nem argumento).
- **Xiaomi (F8)**: protocolo local miIO/MIoT (UDP 54321) em `Miio::Protocol`
  (quadros, sem rede) → `Miio::Client` → `Drivers::XiaomiMiot`. Nada passa pela
  nuvem: o `xiaomi_home` do HA usa OAuth e girar o token dele derruba o robô no
  HA. Dispositivo: `address` {host, model}, `external_id` = did, `credential` =
  token do aparelho (hex, de `.storage/xiaomi_home/miot_devices/*.dict` do HA).
  Ponto: `address` {siid, piid, role, map?}; o `vacuum` leva `actions`
  ({comando → [siid, aiid]}) e `rooms` ([{id, name}] do mapa; junção de
  cômodos no app troca ids: reimporte). Modelo dos pontos em `Miio::Vacuum`
  (X20 Max `xiaomi.vacuum.d109gl`); o robô nasce com leitura a cada 60 s;
  comando lê de novo no fim. `clean_rooms` grava
  só os ajustes que mudaram e manda os ids como texto ("5,45", ação 2.16).
  Importação: `... | rake 'xiaomi:importar[Casa]'` (JSON na entrada padrão).
  Robô: só leitura de teste; nada de limpar, voltar, lavar, secar, esvaziar.
- **Alexa (F8)**: `Alexa::Client` (API não oficial do app, `alexa.amazon.com.br`,
  cookies de sessão já logada + cabeçalho csrf; sem login nem 2FA aqui) →
  `Drivers::Alexa` (`announce`/`speak` em ponto `speaker`). A conta é
  `Integration` (`credentials` cifrado = {cookie → valor}, `status`,
  `last_error`, `last_ok_at`; tela `/locais/:id/integracoes`, "Atualizar
  lista de Echo" só lê). Importação: `cat <cookies do alexa_media> | rake
  'alexa:importar[Casa]'` (só família ECHO/KNIGHT/ROOK). Os cookies são uma
  cópia: quando o HA renovar e a Amazon recusar (401/403), a integração fica
  "Com erro" e é só importar de novo. Canal `alexa:<id do ponto>` em
  `Notifier` (aviso, alerta, ação "Avisar"): manda `announce` pela fila
  (source automation). Nunca anuncie de teste.
- **Leitura periódica (F8)**: `Polling` no worker (`POLLING=off` desliga),
  só leitura: `devices.poll_s`/`integrations.poll_s` (segundos; padrão 1800,
  nulo ou 0 desliga; tela em minutos), `polled_at` = última tentativa. Um
  aparelho por vez com `GAP` (2 s) entre eles; Tuya com `listen` fica de fora.
  Driver com leitura = `poll(device)` + `unavailable!(device)` em
  `Polling::DEVICES` (tuya_local: conexão curta; xiaomi_miot); integração em
  `Polling::INTEGRATIONS` (Alexa: lista de Echo). "Atualizar agora" na página
  do dispositivo (operador+) → `PollDeviceJob`. Tuya: a conexão curta pode
  esbarrar no LocalTuya do HA (aparelho de conexão única); falhou = indisponível.
- **Integrações (F8c)**: plugin por tipo em `app/services/integrations/`,
  registrado em `Integrations::PLUGINS`; nada de `case` por tipo fora dele
  (telas = partials `forms/_<key>` e `connect/_<key>`). Mapas de dp/propriedade
  → ponto em `config/device_maps/*.yml`. Varredura casa pelo `driver +
  external_id` (ou IP com `match: host`): nunca duplica, atualiza chave/IP,
  marca `removed_at`. A nuvem só descobre; o controle é sempre local. Tuya da
  nuvem não traz IP nem versão: IP na edição + Reconectar.
- **Helpers (F8e)**: helper = ponto (`points.helper` = tipo, configuração em
  `address`) do dispositivo virtual "Helpers" do local (`external_id:
  "helpers"`, fora da lista de dispositivos). Cada tipo é um plugin em
  `app/services/helper_types/`, registrado em `HelperTypes::PLUGINS`, com a
  partial `web/site_helpers/forms/_<key>`; nada de `case` por tipo fora dele.
  **Tipo novo** = classe (`describe`, `fields`, `assign` e o que mudar:
  `initial_value`, `commands`, `new_value(cmd)`, `execute`, `actions`,
  `value_text`, `sourced?`/`refresh!`) + linha em `PLUGINS` + partial + spec
  (`docs/helpers.md`). `Points::Command` pergunta ao plugin
  (`commands_for`, `new_value`), o driver virtual entrega o `execute`, e
  `Automations.on_change` chama `HelperTypes.on_change` (refaz grupo, sensor
  calculado e estatística pelas `address.sources`). Temporizador termina por
  `HelperTimerJob` com carimbo (sobrevive a reinício). `restore: false`
  volta ao inicial no início do worker (`HelperTypes.boot!`). Telas e
  widgets desenham pela capacidade/comandos (`commands_for`/`actions_for`),
  nunca pelo tipo de helper.
- Nunca acione de teste portão, sirene, ar-condicionado, irrigação ou
  bomba/filtro da piscina; leitura de estado pode.

## Servidor local (casa)

Debian `192.168.68.199` (`ssh -i ~/.ssh/dell_automacao herlon@…`), em
`/opt/minha-automacao`: `docker-compose.yml` (= `docker-compose.local.yml`),
`.env` (chmod 600, segredos gerados lá; nunca no repo: inclui
`MQTT_PASSWORD` e `Z2M_FRONTEND_TOKEN`), `backups/` (pg_dump diário, 7 dias).
Serviços: db, web, worker, mosquitto (1883 na rede local), go2rtc (só 8555
de mídia exposta), backup, cloudflared (perfil `tunnel`) e zigbee2mqtt
(perfil `zigbee`). `bin/deploy-local [tag]` no WSL: usa a imagem local do
runner (ou puxa), `docker save | ssh docker load`, sobe e espera o `/up`. Web
em `http://192.168.68.199/` (HTTP na rede: `ASSUME_SSL`/`FORCE_SSL=false`).
Túnel: serviço `cloudflared` (perfil `tunnel`) liga sozinho quando o `.env`
tem `CF_TUNNEL_TOKEN`. sudo pede senha; use `docker run -v` para mexer fora
de `/opt/minha-automacao`. Acesso inicial do dono em `acesso-inicial.txt`.

## Web

- Controllers em `app/controllers/web/`, finos, chamando os mesmos serviços
  da API. Caminhos em português (`/entrar`, `/notificacoes`, `/configuracoes`).
- Lista Clara em `app/assets/tailwind/application.css`: menu escuro, toasts,
  `icon("nome")` com os SVG de `app/assets/images/icons` (ícone novo = copiar
  o .svg). Sem emoji/unicode na tela.

## Armadilhas

- Comentário `<%# locals: (...) -%>` só pode ter a assinatura: texto depois
  dela vira código e quebra o template.
- ERB `<% case %>` + `<% when %>` em linhas separadas não compila; use if/elsif.
- `ai_response("k" => v)` sem chaves vira keyword: passe `({ ... })`.
- Request spec com array de objetos precisa de `as: :json`.
- Spec nunca sai para a rede (WebMock): stub de tudo que é externo.
- Nunca nomeie método de controller `process` (é o despacho do Rails).
- `where.not(col: x)` descarta NULL.
- `normalizes` roda depois do cast: decimal com vírgula do formulário precisa
  de setter próprio.
- Modelo tenant-scoped sem empresa atual levanta `NoTenantSet`
  (`require_tenant`): em job, script e spec use `ActsAsTenant.with_tenant`.
- `pg_dump` do container de dev é o 18 (PGDG, `.devcontainer/Dockerfile`): o
  17 do Debian recusa o servidor 18 e o `db:migrate` não gera o structure.sql.
- `Reading`/`ReadingRollup` não têm chave primária: sempre `order(...)` antes
  de `first`, e grave com `insert_all!`/`upsert_all`.
- Partição `readings_default` com linhas do mês impede criar a partição
  daquele mês (o job roda antes do mês começar; se falhar, mova as linhas).

## Deploy

Push no `master` → quality → imagem `ghcr.io/minhasuite/minha-automacao`. O
deploy em `/opt/minha-automacao` (`ms-minha-automacao-{web,worker}`) roda no
CI (`deploy-prod`) e avisa o meulog; produção em
`https://minhaautomacao.minhasuite.com`. Boot com `db:prepare`. Na VPS as variáveis são `MINHA_AUTOMACAO_*`; no
container, nome curto.
