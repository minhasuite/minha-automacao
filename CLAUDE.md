# minha-automacao — guia rápido

Monolito Rails 8.1: web (Hotwire) **e** API `/api/v1` do app Flutter
`minha-automacao-app`, no mesmo processo. É o servidor de automação da
MinhaSuite (casa, loja e fábrica), no lugar do Home Assistant. Roda inteiro
num servidor local (Linux com Docker, túnel Cloudflare para fora); não há
central/borda nem `EDGE=1`. Não há instância na VPS (a de demonstração,
`minhaautomacao.minhasuite.com`, foi desligada em 10/11/2026). Produto em
`../docs/PROPOSTA.md`; modelo de dados, DSL, API e decisões em
`../docs/ESQUEMA-V1.md`; stack em `docs/adr/0001-stack.md`. O padrão da suíte
está na skill `padrao-suite`; aqui só o que é deste repo.

**Estado:** base da suíte (empresa, usuários, auth da API, convites, push,
notificações, IA da instalação, telemetria, páginas legais e conta) +
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
blueprints com importação do HA (`docs/scripts.md`, `docs/blueprints.md`) +
**F8g**: aplicativos (Configurações → Aplicativos, loja, catálogo em
`config/apps/*.yml` e o supervisor com o socket do Docker; `docs/aplicativos.md`) +
**F9**: widget `energy` "Consumo e custo", Alexa Smart Home (OAuth + diretivas
v3 + "Expor para a Alexa"; `docs/alexa-skill.md`), Google Agenda / ICS como
plugin de integração e a ação "Chamar HTTP" com `SafeHttp`
(`docs/api-integracoes.md`). Nada disso é módulo da casa: widget, plugin de
integração, plugin de gatilho/condição/ação e registro de interfaces. +
**Lote 1 (paridade HA)**: PWA + Web Push (VAPID), canais do aviso como
plugins (`Notifier::Channels`) e transportes de push (`Push::TRANSPORTS`),
aviso com botões, imagem e link, gatilho/espera "resposta de aviso",
`continue_on_error` e `response_variable` (`docs/push.md`) + **Lote 2**: IA da
instalação (provedores como plugins em `Ai::PROVIDERS`, chave do usuário
cifrada, Configurações → IA com teste, padrão, limite mensal e uso; ações
"Pedir à IA" e "Gerar dados por IA"; "Perguntar à casa"; `docs/ia.md`) e
conjuntos de dados (aba Dados, ações "Registrar/Consultar dados", helper
Consulta; consultas em `Datasets::AGGREGATES`; `docs/dados.md`) + **Lote 3**:
câmera RTSP/ONVIF como plugin (`CameraPlugin`, `Onvif`, movimento por
PullPoint no `Onvif::Listener`), câmera Tuya por dados no mapa (movimento
decodificado por `Points::Decode`, sensor de pulso `hold_s`, sirene crítica),
sessão própria da Alexa (`Alexa::Auth`: login da Amazon no navegador, 2FA lá,
renovação pelo refresh token; rotina como comando `routine`) e a ação
"Falar" pelos canais de fala do `Notifier` (`docs/cameras.md`) + **Lote 4**:
clima por plugin (`Weather::PROVIDERS`, integração Clima, ação "Ler previsão
do tempo", widget `weather`), widgets como plugins (`Dashboards::Widgets`;
Texto com Liquid e Markdown mínimo), `visible_if` com faixa, OU e tela,
consultas sobre o conjunto de pontos (`Points::Query`: painel, Liquid
`points_where`, `count_points(...)` e afins), eventos (gatilho "Evento",
"Disparar/Esperar evento", `automation_finished`), integração Sistema (disco,
backup, automações e integrações como pontos) e importação de automações e
scripts do HA como blueprints + **Lote 5**: importador do HA completo
(aparelho, início do sistema, horário vindo de ponto, cena, script, helpers,
id do gatilho) com o Jinja comum traduzido para expressão e Liquid
(`Blueprints::Jinja`, entrada `[[chave]]` no texto), gatilho "Sistema
iniciou", sensor calculado com `previous`, "a cada", data e hora e atributos
(`points.attrs`), "para cada" no Repetir e voz (STT/TTS) como capacidade dos
provedores de IA, com as ações "Transcrever áudio" e "Gerar fala". +
**Lote 6**: Tuya na nuvem como no HA (Zigbee atrás do hub, comando por
código do dp, MQTT em tempo real, eventos de botão; `docs/integracoes.md`). +
**F10**: modo sombra (automação, script, cena, local e instalação), linha do
tempo "teria feito", de-para de migração (`ExternalRef`), comparador com
fonte de referência como plugin (Home Assistant) e importação do HA em
sombra (`docs/migracao.md`). + **Lote 7**: Jinja dos blocos `{% %}`,
namespace, `last_changed`, `state_attr`, `is defined` e conjuntos de
entidades (`count_points`), ações "Anotar" e "Recarregar integração",
`rest_command` → "Chamar HTTP", valor do comando por Liquid, etiquetas e
sensores template da tela do HA na importação, item com perda refeito no lugar. +
**Lote 8**: cor de lâmpada pelo mapa de dados (`Points::Color`), gatilho por
atributo, ações "Comandar pontos por consulta" e "Resumo do histórico de
pontos", eventos do robô deduzidos da leitura, som/música/volume na Echo e o
importador do HA usando tudo isso. + **Lote 9**: última fala às Echo como
atributo (`Alexa::LastCalled`, só lê com alguém escutando), `trigger.attrs`,
câmera de nuvem com vídeo sob demanda (`Plugin.stream_url`, Tuya) e
"Limpar cômodos" por texto. + **F7**: API do app Flutter
(`minha-automacao-app`): tempo real pelo `/cable` com o access token,
`Site#points_stream`, `?view=app` nos pontos, quadro da câmera, resposta de
aviso pela API, FCM só de dados no Android e a integração "App do celular"
(`MobileAppPlugin`: bateria, carregando, Wi-Fi e presença como pontos;
`docs/app.md`). + **Paridade HA (vendas)**: Diário e Histórico da
instalação, painel de Energia por plugins (tarifa branca, fluxo, ranking,
comparação, painel pronto), Mapa e o assistente "Migre do HA em 10 minutos". +
**Produto (vendas)**: primeira configuração (`Onboarding::STEPS`), telas em
pt-BR/en/es (`config/locales/web.*.yml`, `Localized`), instalador `install.sh`,
atualização com um clique (`Updates`, `bin/ma-update`, supervisor
`/system/update`; `docs/instalacao.md`), acesso remoto por provedores
(`RemoteAccess`; `docs/remote-access.md`). **Produto aberto** (04/11/2026,
Apache 2.0): sem planos, licença, assinatura nem IA paga da suíte; tudo
liberado, a IA só com a chave da instalação. + **Fila e jobs**:
Configurações → Fila (`QueueMonitor`: Solid Queue, latência dos comandos fila
x aparelho por driver, tentar de novo/descartar; só o dono) e
`GET /api/v1/system/queue` (`docs/fila.md`). + **Tapo**: câmera TP-Link
Tapo como plugin (`TapoPlugin`: ONVIF na 2020 com a conta da câmera,
recursos por modelo em `config/device_maps/tapo.yml`, falar pela fonte
`tapo://` do go2rtc ao lado do RTSP, privacidade/LED/detecção/sirene pela API
local `Tapo::Client` atrás do `FeatureFlag` `tapo_control`;
`docs/cameras.md`). + **Confiabilidade**: nova tentativa só quando nada saiu
(`Transient`), anúncio único por conta da Alexa com ritmo (`Alexa::Throttle`),
execuções sem dono fechadas (`Automations::Sweeper`, status `interrupted`),
automação não comanda aparelho sem sinal (`Reliability`, comando `skipped`) e
avisos de falha repetida pela Saúde e pelo vigia da fila
(`docs/confiabilidade.md`).

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

- **Produto (vendas)**: passo novo da primeira configuração = classe em
  `app/services/onboarding/steps/` (`save` → nil, `:stay` ou erro) + nome em
  `Onboarding::STEPS` + partial `web/onboarding/steps/_<key>`; estado em
  `tenants.settings["onboarding"]`. Sem ninguém cadastrado, tudo leva à
  primeira configuração; dono sem local também, até concluir ou pular.
  **Texto de tela novo vai para `config/locales/web.{pt-BR,en,es}.yml`** (o
  `spec/i18n_spec.rb` exige as mesmas chaves); idioma da pessoa em
  `users.dashboard_prefs["locale"]`. Não há plano nem limite por instalação
  (repo público e aberto): nada de checar licença ou assinatura.

- **Papéis** (`User::ROLES`): `owner` (Dono: tudo, inclusive chaves de
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
  `Accounts::ExportData`.
- **Notificação** com `user` vai só para a pessoa; sem `user`, para dono e
  administradores (`Notification.for_user`, `SendPushJob`). Crie pelo
  `Notifier.notify!` (push + `dedup_key`).
- **Canais e push (Lote 1)**: canal do aviso = plugin em `Notifier::Channels`
  (`owns?`, `choices`, `label`, `capabilities`, `deliver`); transporte de push
  = módulo em `Push::TRANSPORTS` (`Browser` = Web Push, `Fcm`), com
  `capabilities` (`Notifier::FEATURES`): `Push::Message#to_h` corta o que o
  transporte não suporta. Nada de `case` por canal. Resposta de botão: uma vez
  (`responded_at`), token assinado por notificação + pessoa no service worker
  (`POST /push/resposta`), evento `notification_action` por
  `Automations::Triggers.event` (gatilho com `event` no plugin e espera
  `kind: "event"` no motor). Web Push exige https (Dell: só pelo acesso
  externo) e as chaves `VAPID_*` (`bin/vapid-keys`; nunca no repo). Nunca
  mande push de teste para o celular de alguém: teste com navegador headless.
- **`response_variable` e `continue_on_error` (Lote 1)**: ação que devolve
  dados declara `returns` e chama `respond`; a variável é objeto (Liquid
  `{{ r.x }}`, dentaku `r.x`, `lista.count`). Toda ação fora as de controle
  (`control?`) aceita `continue_on_error` (passo "erro tolerado").
- **IA da instalação (Lote 2)**: provedor = classe em `app/services/ai/providers/`
  (`Ai::Providers::Base`: `describe` com `capabilities` e `complete`) + nome
  em `Ai::PROVIDERS`. Não há IA da suíte (chave em env): chave do usuário em `AiAccount.api_key`
  (`encrypts`), nunca na tela, no log ou no `.env`. Toda chamada passa por
  `Ai::Request` (conta, limite `Ai::Budget`, capacidades) e vira um `AiCall`
  sem prompt nem resposta. Ollama pelo `SafeHttp` (IP da LAN em `http_allow`).
  Spec nunca chama provedor de verdade (WebMock ou provedor falso por
  `stub_const`).
- **Dados (Lote 2)**: `Dataset`/`DatasetRecord` por local; consulta pelo
  `Datasets::Query` (tipo em `Datasets::AGGREGATES`, filtro em
  `Datasets::OPERATORS`), nunca SQL do usuário. Gravar refaz os helpers
  Consulta pela `address.sources` (= id do conjunto). Campo de select com
  opções vindas de registro: `options: -> { ... }` e `fd.choices`.
- **Credencial vazia = feature desligada:** Google, FCM, R2, meulog, SMTP.
- `encrypts` exige `AR_ENCRYPTION_*` em produção (dev/teste derivam do
  `secret_key_base`).
- **Comandos (F2)**: `Points::Command.call(point, cmd, value, source:)` valida
  (422 antes de criar), cria o `Command` e roda o `ExecuteCommandJob`: na hora
  no driver `virtual`, na fila nos outros. API responde **202** com o
  comando. Status `pending → sent → confirmed | failed | expired` (na fila há
  mais de `Command::TTL` = expira, não executa) e `skipped`. Driver novo = classe com
  `execute(point, command, value)` em `Drivers::REGISTRY` [+ `execute_group(points, …)`
  se entrega vários pontos numa chamada].
- **Confiabilidade** (`docs/confiabilidade.md`): repetir só com
  `Transient.retryable?` (conexão que nem abriu ou 429/5xx marcado com
  `Transient::Busy`; ponto crítico só a conexão); erro de rede novo de
  cliente = embrulhe dentro do `rescue` (a `cause` fica) ou inclua
  `Transient::NotSent`/`Busy`, nunca repita `ReadTimeout`. O comando volta a
  `pending` (`attempts`) e o `ExecuteCommandJob` se reagenda dentro do TTL;
  push repete só o aparelho que falhou (`deliver_some`). Alexa: vários
  `alexa:<ponto>` da mesma conta = um `announce` (`call_group`, `batch_id` =
  líder; canal com `deliver_all`/`speak_all`). `source: "automation"` em
  aparelho sem sinal há `dead_device_hours` (24) = `skipped`, sem driver;
  pessoa sempre tenta. Ajustes em `tenants.settings["reliability"]`. Recorrente
  própria no bloco "confiabilidade" do `config/recurring.yml`.
  Estado real: conferência da nuvem Tuya a cada 10 min no `CloudListener`,
  "Redefinir estado" (`Points::Reset`, técnico+, AuditEvent; releitura não
  desfaz até o aparelho empurrar) e sensor aberto além de `address.stale_open_s`
  = qualidade `stale` + um aviso (`Points::Stale`).
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
  "automacao"`. No Dell o local Casa fica em sombra (F10) até o corte.
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
- **zigbee2mqtt (F8, aplicativo desde a F8g)**: app `zigbee2mqtt` do catálogo,
  não instalado até o coordenador USB chegar. Descoberta: `zigbee2mqtt/bridge/devices` (retido) →
  `Mqtt::Z2m.discover!` (dispositivo por `ieee_address`, ponto pela
  propriedade, chave `nome_z2m.propriedade`; exposes binário/numérico/enum/
  texto → onoff, contato, movimento, problema, medição, dimmer, setpoint,
  enum, evento). Local: `Z2M_SITE_ID` ou o único local do servidor.
  **Para ligar:** no Dell, `ls /dev/serial/by-id/`; em Configurações →
  Aplicativos → Zigbee2MQTT, instale com esse caminho e o tipo (`ember` para
  Sonoff ZBDongle-E/EFR32, `zstack` para ZBDongle-P/CC2652). Frontend do z2m
  em `:8080` com `Z2M_FRONTEND_TOKEN` do `.env`. Parear pelo frontend.
- **Câmeras (F8; Lote 3 em `docs/cameras.md`)**: plugin `CameraPlugin` para
  câmera avulsa (RTSP colado, usuário/senha tirados da URL; ou ONVIF com
  perfis e ponto `motion` por PullPoint no `Onvif::Listener`,
  `ONVIF_LISTENER=off` desliga). Dispositivo `go2rtc` (`address` {scheme?, host, port, username, onvif_port?},
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
- **Alexa (F8; login próprio no Lote 3)**: `Alexa::Auth` faz o login como o
  app Alexa (PKCE no navegador da pessoa, ela cola o endereço final com o
  código; `/auth/register` → refresh token + cookies; `refresh!` por
  `/ap/exchangetoken/cookies`). Senha e 2FA nunca passam pelo servidor;
  credenciais = {cookies, refresh_token, serial}, cifradas. O cliente renova
  uma vez no 401/403 (`renew:`). Spec só com WebMock; nunca use login,
  cookie ou token do HA nem fale numa Echo de teste. Antes (ainda vale como
  modo avançado): `Alexa::Client` (API não oficial do app, `alexa.amazon.com.br`,
  cookies de sessão já logada + cabeçalho csrf) →
  `Drivers::Alexa` (`announce`/`speak` em ponto `speaker`). A conta é
  `Integration` (`credentials` cifrado = {cookie → valor}, `status`,
  `last_error`, `last_ok_at`; tela `/locais/:id/integracoes`, "Atualizar
  lista de Echo" só lê). Importação: `cat <cookies do alexa_media> | rake
  'alexa:importar[Casa]'` (Echo = família ECHO/KNIGHT/ROOK, com o ponto
  `speaker`; Fire TV e grupo de alto-falantes = FIRE_TV/WHA, só com a mídia:
  aviso continua só nas Echo). Os cookies são uma
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
- **Valor empacotado e sensor de pulso (Lote 3)**: endereço do ponto com
  `decode` (`Points::Decode::DECODERS`), `field`, `match` (nil = ignora),
  `hold_s` (volta a falso, `PointHoldJob` com carimbo `reported_at`) e
  `push_only` (Tuya: só o dp empurrado conta). Vem do mapa de dados, nunca
  de código por aparelho.
- **Integrações (F8c)**: plugin por tipo em `app/services/integrations/`,
  registrado em `Integrations::PLUGINS`; nada de `case` por tipo fora dele
  (telas = partials `forms/_<key>` e `connect/_<key>`). Mapas de dp/propriedade
  → ponto em `config/device_maps/*.yml`. Varredura casa pelo `driver +
  external_id` (ou IP com `match: host`): nunca duplica, atualiza chave/IP,
  marca `removed_at`. Tuya (Lote 6): aparelho da conta é `tuya_cloud`
  (comando por `address.code`, `Drivers::TuyaCloud`), sub-dispositivo do hub
  adotável com `address.via`, tempo real pelo MQTT da conta
  (`Tuya::CloudListener`, `TUYA_CLOUD_LISTENER=off`), `match_drivers` casa
  com o `tuya_local` do mesmo device_id (não duplica; comando local, sem IP
  vai pela nuvem). Estado depois da varredura/adoção pelo `Plugin.refresh`.
  Ponto `event` dispara a cada aviso (clique repetido). Login QR próprio: não
  derruba o HA. Nunca comande de teste fechadura, sirene ou AR pela nuvem.
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
- **Aplicativos (F8g)**: o Rails NUNCA monta o socket do Docker; só o
  serviço `supervisor` (`supervisor/server.rb`, imagem do app, `:8099` só na
  rede interna, `SUPERVISOR_TOKEN`). Catálogo = manifestos em
  `config/apps/*.yml` lidos por `lib/app_catalog.rb` (Ruby puro, usado pelos
  dois lados): imagem/portas/volumes/rede/devices só do manifesto, do pedido só
  as opções do schema. App novo = um YAML + spec do catálogo verde, nada de
  código (`docs/aplicativos.md`). Containers `ma-app-<chave>` com o label
  `minha-automacao.app`; o supervisor só mexe neles e, nos apps do sistema
  (Mosquitto, go2rtc), só status/log/reiniciar. Web só para o Dono, ação vira
  `AuditEvent` `app.<ação>`. "Abrir interface" redireciona para a porta do app
  na rede de casa (sem proxy: websocket). Sem `SUPERVISOR_URL` (VPS) só o
  catálogo. **Apps (11/2026, aberto/fechado)**: manifesto com `command`,
  `cap_add` (só `AppCatalog::CAPS`), `sysctls` (só `SYSCTLS`), `ram_mb`
  (>= 1 GB = "Pesado") e `connect` (`integration:` plugin ou `ai:` provedor,
  `{host}` = IP do servidor; o "Conectar" libera o IP no `http_allow`); porta
  baixa só em `LOW_PORTS` (53); app de terceiro não usa nenhum desses.
  Provedor que prepara algo ao conectar = `self.prepare(account)`
  (`AiPrepareJob`). Descobridor MQTT novo = módulo em
  `Mqtt::Listener::DISCOVERY` (`DoubleTake`, `Espresense`). InfluxDB exporta
  em lote pelo `tick`, fora do `StateReport`. Dozzle fica de fora (socket).
- **Saída HTTP (F9)**: todo pedido para endereço digitado pelo usuário passa
  por `SafeHttp` (IP interno bloqueado, conexão presa ao IP checado, redirect
  rechecado). Liberação por instalação em `tenants.settings["http_allow"]`
  (Configurações → Sistema). Nunca use `Net::HTTP` direto com URL do usuário.
- **Ação `http` (F9)**: campo `:secret` cifrado na DSL (`{"enc" => …}`),
  `{{ secret }}` só na montagem dos textos; trace mostra só o host.
- **Energia (F9)**: é só o widget `energy` (`Dashboards::Energy`, rollups de
  hora + valor atual), sem tabela nem tela própria. Tarifa = número ou ponto.
- **Agenda (F9)**: plugin `calendar` (`Integrations::CalendarPlugin`,
  `Calendars`): ponto `calendar` por agenda com `address.events`; o relógio
  das integrações é `Integrations.tick` (plugin com `tick(now)`), chamado pelo
  RunSchedulesJob antes dos gatilhos. OAuth de plugin: `oauth_callback` +
  `/integracoes/oauth/retorno` (state assinado). Modo Google só com
  `GOOGLE_CLIENT_ID` e `GOOGLE_CLIENT_SECRET`.
- **Entrar com Google** (`GoogleLogin`, `User.from_google!`): web pelo botão
  GIS (controller `google-signin`, `POST /entrar/google`), app por
  `GET /api/v1/auth/providers` + `POST /api/v1/auth/google`; aud = clients
  configurados, e-mail verificado, convite e duas etapas respeitados;
  vincular em Segurança. Clients e ENVs: `docs/login-google.md`.
- **Alexa Smart Home (F9)**: o vínculo é um `ApiToken` com `client: "alexa"` e
  `site_id`; o código de autorização é o próprio registro antes do primeiro
  uso (5 min; a rotação o consome). `ApiToken.find_by_access` só aceita
  `client: nil` (app) e `find_alexa` só o da Alexa. Cliente OAuth da
  instalação em `tenants.settings["alexa"]` (segredo só em digest). Interface
  nova = classe em `Alexa::SmartHome::Interfaces::PLUGINS` (`applies?`,
  `capability`, `properties`, `handle`). Exposição: `points/scenes.alexa_exposed`
  (padrão falso) e `alexa_name`; crítico só com `alexa_risk_confirmed`. No Dell
  nada fica exposto: teste com token temporário e revogue.
- **Lote 4 (aberto/fechado)**: widget novo = classe em
  `Dashboards::Widgets::PLUGINS` (`describe type:, label:, required:, params:,
  bind:`, `errors`, `data`, `attrs`, `form`) + partial; o `case` do Resolver e
  do controller do painel ficou só com os tipos da F5 e cai no plugin no
  `else`. Provedor de clima = classe em `Weather::PROVIDERS` (formato comum em
  `weather.rb`). Filtro de consulta = linha em `Points::Query::FILTERS`
  (lambda); a mesma consulta serve ao painel, ao Liquid (filtro
  `points_where`, registrado só no render do `Automations::Context`) e ao
  dentaku (`Expr::AGGREGATES`, funções por calculadora com o contexto).
  Sensor calculado com consulta tem `sources` `["*"]` (refeito pelo `HelperStarRefreshJob` com debounce, nunca síncrono). Evento: plugin de
  gatilho responde `listens?(nome)`; `Triggers.event(site, nome, dados,
  cause:)` sempre põe `event` e `data` no payload; a ação `fire_event` não usa
  nome reservado (`Triggers::SYSTEM_EVENTS` e os `event` dos plugins). Medida
  do Sistema = entrada em `SystemPlugin::METRICS`. Importar do HA: cada
  entidade fixa vira entrada de ponto do blueprint (nada de mapear entity_id
  por nome).
- **Painel por dado (aberto/fechado)**: "o que existe" é só `Points::Query.exists?`;
  item de cartão = dado (`Dashboards::Facts`: `facts` no widget ou o padrão do local em
  `sites.settings["dashboard_defaults"]`, Configurações → Painéis → Padrões); estilo =
  `style_if` (`Dashboards::Style`, avaliado no `Resolver#decorate`); topo = `hero` da visão
  (`Dashboards::Hero`, `hero_now`); lista de um número = `drill` no plugin do widget
  (`/paineis/:id/w/:wid/pontos`); "dado velho" = `Dashboards::Staleness`. Nada disso tem
  `case` por tipo; ver `docs/dashboards.md` ("Painel por dado").
- **Arrumação como dado (aberto/fechado)**: colunas, selos e ícones das visões de cômodo e
  luz/técnico/segurança/potência do painel automático são consultas (`Dashboards::Arrange`:
  `arrange` no painel ou no local, `auto_rules` no local; Configurações → Painéis → Regras de
  arrumação); visão com `auto` se refaz a cada leitura até congelar (`Dashboards::AutoViews`);
  montagem por frase só pela IA da instalação, no rascunho (`Dashboards::Compose`); assistente
  = `Dashboards::Wizard`. Ver `docs/dashboards.md` ("Arrumação como dado").
- **Agilidade do editor (aberto/fechado)**: tudo vai para o **rascunho** por
  `Dashboard#save_draft!` (pilha de desfazer `dashboard_draft_steps`,
  `Dashboards::History`; publicar zera) e publicar passa pela revisão
  (`/paineis/:id/revisar`: prévia em iframes `?embed=1` + avisos do
  `Dashboards::Lint`, que não bloqueiam e olham pela chave do JSON). JSON Schema =
  `Dashboards::JsonSchema` do registro (prop própria do plugin em `schema_props`);
  "Adicionar ao painel" = linha em `Dashboards::AddTo::SOURCES`; ação de painel
  no Ctrl+K = `Search::DashboardActionsSource`; área de transferência em
  `users.dashboard_prefs["clipboard"]`. Ver `docs/dashboards.md` ("Agilidade do editor").
- **Painel do dia a dia (aberto/fechado, ideias 9–13 e 23)**: condição nova do `visible_if`/`style_if`/
  `order_if`/`open_if` = classe em `Dashboards::Context::CONDITIONS` (sol e presença hoje); ação em lote =
  ação `command_query` do `Dashboards::Actions` (`Dashboards::Batch`: consulta só da definição publicada,
  papel x risco por ponto, crítico nunca); botões rápidos = `quick_actions` (ou o padrão do local por tipo);
  busca e favoritos pós-cache em `Dashboards::Personal`; painel por aparelho = `PanelDevice` (cookie
  `ma_device` / cabeçalho `X-MA-Device`); link de convidado = `GuestLink` (`viewer`/`guest`, só widgets com
  `guest: true`, nunca crítico, auditado); "Saúde da casa" = `Presets::HealthPreset`. Ver
  `docs/dashboards.md` ("Painel do dia a dia").
- **Beleza dos painéis (aberto/fechado, `docs/dashboards.md` "Beleza")**: noite do tema pelo sol
  ou janela (`Themes.night?`, sem hora fixa), fundo por hora = faixas `backgrounds` no `theme`
  (dado), visão `plan` = classe em `ViewTypes::PLUGINS`, visão inicial = `start_view`, aceno de
  estado = `ss-cue`/`SsCue` da gem (nada de animação própria), widget só da web = `web_only?` no
  plugin (o app mostra "abrir na web"), álbum do quiosque = anexos do painel com `metadata.album`.
- **Lote 5 (aberto/fechado)**: serviço do HA novo no importador = linha em
  `HaImport::SERVICES` (método) ou `HELPER_COMMANDS`; o `case` do
  `HaImport#trigger`/`#condition` traduz a sintaxe do YAML do HA, não tipos
  daqui. Tradução de Jinja só no `Blueprints::Jinja` (o que não cobre devolve
  nil e o importador anota). Entrada de blueprint que escolhe registro do
  local = linha em `Blueprint::RECORD_INPUTS`. Voz: capacidade `stt`/`tts`
  em `Ai::CAPABILITIES`, provedor implementa `transcribe`/`speak` e declara
  `stt_model`/`tts_model`/`tts_voice`; `AiAccount.pick(capability:)` separa
  texto de voz. Fala gerada = anexo com URL assinada de 1 dia
  (`Ai::Audio.store`, apagada pelo `ActiveStorage::PurgeJob`). Evento
  `system_started` pelo `SolidQueue.on_start` (supervisor, uma vez por
  início). Sensor calculado "a cada" não depende das origens (`sources` vazio)
  e se refaz no `HelperTypes.tick` (RunSchedulesJob).
- **Lote 7 (aberto/fechado)**: integração do HA → daqui é dado
  (`HaImport::HA_PLUGINS` para recarregar e `integration_ok`, `HA_DRIVERS`
  para a consulta `integration=`); serviço que só anota no diário =
  `HaImport::LOG_SERVICES`. Os `case` novos do `Blueprints::Jinja` olham a
  árvore do Jinja e os estados do HA (on/off/unavailable), não tipos daqui.
  Variável do Liquid em volta (`assign`, item do `for`) chega ao `| calc`
  (`Context#calc(expr, locals)`); na expressão, `ponto.changed_at` são os
  segundos da última mudança e `defined('x')`, `to_timestamp(x)` e
  `integration_ok('tipo')` são funções da calculadora (`Automations::Expr`).
  Comando com valor `{{ }}` é texto Liquid resolvido na execução
  (`Dsl.template?`). `shell_command` do HA não tem equivalente de propósito
  (rodar comando no servidor de uma instalação multi-cliente não é seguro).
- **Lote 8 (aberto/fechado)**: formato de cor = linha em
  `Points::Color::FORMATS` ([codificar, decodificar]); o mapa de dados diz o
  formato, o `via` (driver) e os endereços irmãos (temperatura, modo). Driver
  grava `Point#raw_writes(valor, via)` quando não é um dp só (nil = `to_raw`).
  Evento deduzido do robô = linha em `vacuum_events` do `miot.yml`. Atributo
  de ponto muda só por `Point#report_attrs!` (dispara o gatilho `state` com
  `attribute`; o valor do gatilho não é convertido). Ponto novo do mapa entra
  no aparelho já cadastrado pela varredura (`Integrations.add_points`).
- **Lote 9 (aberto/fechado)**: vídeo de nuvem = `stream_url(point)` no
  plugin da integração + ponto `stream` com `address.on_demand` (Tuya:
  categoria em `streams` no `tuya.yml`). Atributos de Echo vêm do histórico
  de voz só quando uma automação ligada escuta (`Alexa::LastCalled.listened?`).
  Comandar por consulta e resumo do histórico são plugins de ação; o `case`
  do `PointsHistoryAction#row` escolhe a opção da própria ação (op), não tipo
  daqui. Importador: item publicado e solto do blueprint não é refeito.
- **Pacote 1 (aparelhos, aberto/fechado)**: aparelho da rede = plugin
  `< Integrations::LanPlugin` (uma integração por aparelho: `port`,
  `secrets`, `mdns`, `probe` → entrada) + driver em `Drivers::REGISTRY`
  (+ `Polling::DEVICES` se lê); `Device` aceita qualquer driver registrado.
  Mídia e controle remoto são capacidades (`media`, `remote`), não marcas:
  o aparelho diz o que faz em `address.supports` (corta
  `commands_for`) e o widget sai da capacidade (`Widgets.for_capability`,
  `describe auto:`), no painel automático e na página do ponto. Transporte de
  controle remoto = driver com `send_code`/`learn` chamando `Remotes.execute`
  (códigos em `address.codes`). Descoberta (`Mdns.browse`) só lista; na rede
  bridge do Docker o multicast não sai: `MDNS_SUBNET` liga a pergunta unicast
  por IP. Protobuf em `Proto`, WebSocket em `WsClient`. Detalhes em
  `docs/integracoes.md` (Pacote 1).
- **Pacote 3 (plataforma, aberto/fechado)**: pessoa, zona e painel de alarme
  são **helpers** (`person`, `zone`, `alarm_panel`); rastreador de presença =
  classe em `People::TRACKERS`, sonda de rede em `NetworkTrackerPlugin::PROBES`,
  modo de alarme em `AlarmPanel::MODES`, intenção de voz em `Assist::INTENTS`,
  fonte e tipo de item de pacote em `Packages::SOURCES`/`ITEMS`, mapa somável
  em `DeviceMaps::MERGEABLE` (Tuya/MIoT leem por `DeviceMaps.apply`). Código
  do alarme só em bcrypt e fora da tabela de comandos (`Points::Command#value=`
  no `new_value`; API mostra `public_address`). Coordenada exata só nos
  atributos do "Presença" do celular, apagada pelo `MobileAppPlugin.tick`
  (`location_keep_h`). Voz e Ferramentas comandam por `Shadow.for_site` e a
  voz nunca comanda ponto/cena crítica. Pacote nunca executa nada.
  Ferramentas: só `user.admin?`. Docs: `presenca.md`, `alarme.md`,
  `assistente.md`, `pacotes.md`, `ferramentas.md`.
- **Sombra (F10)**: `Shadow.active?` = marca da automação/cena, `sites.shadow`
  ou `tenants.settings["shadow"]`; a execução guarda `automation_runs.shadow`
  (herda de quem causou e da thread). Ação nova = **segurada** por padrão:
  só declare `shadow_safe?` se ela não sai para fora (aparelho, aviso, rede,
  IA paga); a segurada roda pelo caminho da simulação (`dry_run?`) e vira
  `ShadowAction` (`shadow_effects` = pontos e comandos). Rede de segurança:
  `Shadow.intercept!` no `Points::Command.call` e `Shadow.block!` no
  `Notifier`, `SafeHttp` e `Ai::Request`; comando em helper que não comanda
  ponto (`drives_points?` falso) e em ponto de script roda e fica registrado
  (`executed`). Saída nova para fora = chamar `Shadow.block!` nela + spec no
  `f10_shadow_spec` (o teste percorre todas as ações registradas). Fonte de
  referência do comparador = plugin de integração com `reference` e
  `state_for`; de-para em `ExternalRef` (`source` = chave do plugin).
- **App (F7)**: o app só desenha o que o servidor resolve; regra de
  negócio (papel x risco, `can_command`, texto do valor) fica aqui. O
  `/cable` aceita `?access_token=` (só token do app, `ApiToken.find_by_access`)
  e o cliente manda `Origin` = endereço do servidor. Push FCM para Android é
  só de dados (`Push::Fcm`): mudou o formato, mudou o `Notices.show` do app.
  Aparelho do celular é da pessoa (`address.user_id`): só ela manda leitura
  ou remove. Sensor novo = linha em `MobileAppPlugin::SENSORS`.
- **Pacote 2 (helpers de medição)**: medidor por ciclo, integral, derivada,
  limite e tendência são plugins de `HelperTypes` (mediana entrou no Grupo e
  na Estatística). Estado interno do cálculo em `address.state`
  (`Plugin.state`/`save_state!`, sem disparar nada); o visível em `attrs`.
  Tipo com relógio = `clocked?` + `tick(point, now)` (o `HelperTypes.tick`
  chama). Ciclo do medidor = cron do `Fugit` no fuso do local. Ponto que só
  muda de qualidade também refaz os helpers dependentes (`docs/helpers.md`).
- **Pacote 4 (mensageiros)**: canal `messenger:<integração>`
  (`Notifier::Channels::Messenger`) para todo plugin de integração com
  `send_message`; Telegram, WhatsApp (Cloud API) e gateway HTTP são só
  plugins. Respostas de botão por `webhook(integração, request)` em
  `/mensageiros/:id` (o plugin valida) ou pela leitura do Telegram no worker
  (`TELEGRAM_LISTENER=off`). Nunca mande mensagem de verdade de teste
  (`docs/push.md`).
- **Corte (aberto/fechado)**: verificação de saúde = classe `< Health::Check`
  (`describe key:, label:, icon:`, `items(tenant)` → `Health::Item`) + nome em
  `Health::CHECKS` (tela Configurações → Saúde, só administradores; erro vira
  aviso diário pelo `HealthCheckJob`). Requisito da troca = linha em
  `Cutover::REQUIREMENTS` (`rake cutover:check`, `docs/cutover.md`). Cópia
  fora de casa (G20) = `Backups` (cifra no formato do `openssl enc`) + destino
  em `Backups::DESTINATIONS` (SSH e S3; `docs/backup.md`); sem
  `BACKUP_OFFSITE_URL`/`BACKUP_PASSPHRASE` fica desligada. Papel por local
  `viewer` (Leitor): só passa no controller que declara `viewer_allowed?`
  (painel, ponto, câmera; na API painéis, pontos, locais e o próprio
  celular); `User#reader?` esconde menu e Configurações. Dado sensível (IP,
  usuário, URL, token, MAC) só para técnico/dono: `Sensitive` (chave nova em
  `KEYS`), serializers com `params: { reveal: }` (padrão é ocultar) e
  `reveal_sensitive?` na tela. Echo: ponto novo = linha em
  `Alexa::State::POINTS`.
- **P3 personalização (aberto/fechado)**: problema da casa sem código =
  `CustomHealthCheck` (consulta + expressão + texto, entra pela verificação
  `custom` de `Health::CHECKS`); texto de aviso/alerta = Liquid pelo
  `MessageTemplate` (contexto do `Automations::Context`; prévia com
  `preview=1` no create/update do `AutomationController`); voz = frase → cena
  ou script (`AssistCustomIntent`, intenção `custom`) e resposta
  (`AssistCustomResponse`, lida pelo `Intent.text` com `Assist.with_site`).
  Intenção ou verificação nova do produto continua plugin. `docs/personalizacao.md`.
- **Distribuição** (`docs/PROPOSTA-distribuicao.md`): master verde = beta
  `vX.Y.Z-beta.N` (pré-release criada pelo CI), estável = beta promovida pelo
  `promover-estavel.yml`; canal e "atualizar sozinho" por servidor em
  `storage/update-settings.json` (`Updates.settings`), `Updates::Auto` no
  `UpdateAutoJob`. Versão só por `Updates.newer?` (beta < estável do mesmo
  número; a beta não volta para a estável dela). Fonte nova de versões
  implementa `latest(channel)`.
- **Painéis do HA** (`docs/dashboards.md`, fim): `Dashboards::HaImport` traduz
  o Lovelace resolvido com a mesma disposição (card novo = entrada em `CARDS`,
  nada de `case` por card fora dele); `Integrations::HaDashboards` busca e
  publica. Painel do app à parte (`dashboards.app_default`,
  `Dashboard.default_for(app: true)`). Ícone `mdi:nome` em qualquer lugar.
  Entidade do HA sem aparelho (clima, speedtest, o servidor) = linha em
  `HaServiceEntities::SERVICES` (passo "Serviços" do importador; cria só a
  integração que não pede nada); ação MIoT do HA (`_a_<siid>_<aiid>`) vira
  de-para `command:<comando>` no ponto que tem a ação, e o painel faz o toque
  com esse comando; DP do Tuya do HA com outro nome = `TUYA_CODES`. Toda
  automação tem um ponto `onoff` no dispositivo virtual "Automações"
  (`AutomationPoints`, fora da lista; ligar exige publicada; roda na sombra).
  Sensor template em YAML vem do `configuration.yaml` enviado no assistente
  (`HaMigration.templates_from`; o com gatilho fica anotado). Energia do Tuya
  (`add_ele`) é acréscimo: o ponto soma o que o aparelho empurra
  (`accumulate` + `push_only`) e começa do total do HA. Card statistic do HA
  = stat com `aggregate: "change"` e `period`.
- **Paridade com o HA (roadmap de vendas, compat)**: Diário = fontes em
  `Logbook::SOURCES` (`describe` + `fetch(filtro)`; cadastro técnico+,
  entradas só dono; cena acionada vira evento `scene`, entrada na web/app
  vira AuditEvent `login`), Histórico de vários pontos pelo
  `Points::Overlay` (`docs/diario-historico.md`). Energia: helper `tariff`
  (tarifa branca; widget de energia com `tariff_point` nele cobra hora a
  hora pelo `price_at`), widgets `energy_flow`/`energy_breakdown`/
  `energy_compare` e predefinição de painel em `Dashboards::Presets`.
  Mapa: `Maps` (só morador para cima, `Maps::MIN_ROLE`), widget `map`,
  Leaflet 1.9.4 por importmap (só carrega com mapa na tela), trajeto no
  atributo `track` do "Presença" do app (some com a coordenada). Assistente
  "Migre do HA" (`Integrations::HaMigration`, `HaMigrationJob`) por cima
  do `HomeAssistantImport` (progresso por `STEPS`); spec só com HA falso.
- **Desempenho (aberto/fechado, `docs/desempenho.md`)**: pontos do local e painel
  resolvido em cache curto na memória (`Dashboards::Cache`, chave = carimbo do local
  pelo `xmin`; painel por papel+minuto, 60 s; desligado nos testes). Aviso de mudança
  só pelo `Points::Broadcast` (medição agrupada em 1,5 s por ponto, `address.notify_s`).
  Banda morta padrão por unidade = linha em `config/deadbands.yml`. Tela de câmera usa
  `Drivers::Go2rtc.frame` (nuvem/caída em segundo plano, `?w=`; o `snapshot` síncrono
  fica para IA/aviso). Tarefa lenta = `include SlowJob` (fila `slow`, semáforo
  `JOB_SLOW_THREADS`), nunca um segundo processo de worker. Tempo por tela/widget no
  `Perf` (Saúde → Desempenho).
- Nunca acione de teste portão, sirene, ar-condicionado, irrigação ou
  bomba/filtro da piscina; leitura de estado pode.

## Servidor local (casa)

Debian `192.168.68.199` (`ssh -i ~/.ssh/id_ed25519 herlon@…`), em
`/opt/minha-automacao`: `docker-compose.yml` (= `docker-compose.local.yml`),
`.env` (chmod 600, segredos gerados lá; nunca no repo: inclui
`MQTT_PASSWORD`, `Z2M_FRONTEND_TOKEN` e `SUPERVISOR_TOKEN`), `backups/` (pg_dump diário, 7 dias).
Serviços: db, web, worker, mosquitto (1883 na rede local), go2rtc (só 8555
de mídia exposta), supervisor (aplicativos; socket do Docker, sem porta),
backup e cloudflared (perfil `tunnel`). Apps instalados (`ma-app-*`) ficam
fora do compose, na rede `minha-automacao-apps` ou na `bridge`. `bin/deploy-local [tag]` no WSL: usa a imagem local do
runner (ou puxa), `docker save | ssh docker load`, sobe e espera o `/up`. Web
em `http://192.168.68.199/` (HTTP na rede: `ASSUME_SSL`/`FORCE_SSL=false`).
Túnel: serviço `cloudflared` (perfil `tunnel`) liga sozinho quando o `.env`
tem `CF_TUNNEL_TOKEN`. sudo pede senha; use `docker run -v` para mexer fora
de `/opt/minha-automacao`. Acesso inicial do dono em `acesso-inicial.txt`.

## Web

- Controllers em `app/controllers/web/`, finos, chamando os mesmos serviços
  da API. Caminhos em português (`/entrar`, `/notificacoes`, `/configuracoes`).
- Lista Clara vem da gem `componentes_ui` (tag no `Gemfile`, hoje `v0.21.0`; no branch `beleza`,
  temporariamente o branch `beleza` da gem, a v0.21 com `ss-cue` e `level:`):
  tokens, `.ss-*`, `Ss::*Component` e os controllers `ss-*` (`controllers/index.js`
  carrega os da gem). **Componente primeiro**: tela nova ou mexida usa o
  `Ss::*Component` (exemplos na vitrine da gem, `rails/sample/app/views/vitrine/`);
  classe `.ss-*` solta só onde não há componente; peça genérica que falta nasce na
  gem (skill `lista-clara`), nunca aqui.
- Moldura: `Ss::AppShellComponent` no layout (`shell_nav` com separador antes de
  Configurações, selo 0 some; `tenants:` só no Diário/Histórico/Mapa pela
  `web/shared/_site_switch`; `main_max: "80rem"` a não ser com `content_for :wide`) e
  `ss_app_shell_head` no `<head>` (menu recolhido no `<html>`, sobrevive ao morph).
  "Falar com a casa" é o `Ss::FabComponent` do layout (`web/assist/_fab`, fora do `<main>`, local pelo
  `assist_site`), em toda tela; o topo do painel é o `Ss::PageComponent(eyebrow:, compact: true)` com o
  editar só em ícone (sem herói em degradê, sem atalho "Painéis").
  Cabeçalho pelo `web/shared/_header` (`Ss::PageComponent` só com o topo); vazio pelo
  `Ss::EmptyStateComponent` (com a ilustração do produto: `web/shared/_empty_art`,
  `with_art`); tabelas pelo `Ss::DataTableComponent` com ordem no servidor
  (`TableSort`); paleta Ctrl+K `Ss::CommandPaletteComponent` (`web/shared/_palette`,
  grupos e subtítulos do `/busca`).
- `icon("nome")` (SVG de `app/assets/images/icons`, ou `mdi:nome`) vai direto nos
  `icon:` dos componentes; passe `icon("x", "")` para o componente dimensionar.
  Ícone novo = copiar o .svg e pôr o nome em `config/locales/icons.yml` (rótulo do
  `IconPickerComponent`). Sem emoji/unicode na tela.
- Confirmação: `Ss::ConfirmDialogComponent` global no layout; todo
  `data-turbo-confirm` abre ela. Ação que apaga/remove leva
  `turbo_confirm_tone: "danger"` e `turbo_confirm_button:` (o verbo); comando de
  ponto com risco vai pelo `confirm_title:` dos componentes (`SwitchComponent`,
  `DeviceTileComponent`) com o risco no título.
- Fuso: gráfico, faixas e diário recebem `time_zone:` com o fuso IANA do local
  (sem `Time.use_zone` na view).
- CSS: o `application.css` importa o build da gem e depois os CSS de tela, **só de
  domínio** — a allowlist fica no topo de cada arquivo (comentário "domínio:") e no
  `bin/conferir-css` (`CSS_DOMINIO`; o `spec/conferir_css_spec.rb` roda ele): grade/pilha do
  painel, arte viva dos pontos e o robô, planta (`dw-fp*`/`dw-fpe*`), editor (`dw-ed*`, `dw-wf`,
  `dw-act`), gestos, temas no `<body>` e quiosque (`dashboards.css`, `paineis.css`), tela do
  Leaflet e pinos (`mp-`, `paridade.css`), primeira configuração e ilustrações (`ob-`/`oba-`,
  `produto.css`), diagrama da voz (`vz-`, `voz.css`) e a arte do vazio (`ma-ea-*`). **Nada de
  peça genérica aqui** (v0.14 fechou o resto): card `ss-card ss-card-pad` + `Ss::CardHeaderComponent`,
  frase no lugar do conteúdo `Ss::NoteComponent`, linhas `.ss-item`, ícone `.ss-icon-tile` (`.is-heat`,
  foto dentro), botão no herói `.ss-btn.is-on-grad`, tarefa `.ss-checklist [role=checkbox]` + `.ss-checklist-x`,
  galeria de temas `label.ss-swatch` (`dw_swatch_style`), barras `.ss-bars`, `.ss-progress`, `.ss-delta`,
  `.ss-label-chip`, player/etapas dentro de card com `css: "is-flush"`, vidro do tema pelos tokens
  `--ss-card-bg/-border/-filter`; regra em cima de `.ss-*` é proibida (o `conferir-css` barra). Layout
  sem identidade visual vai em utilitário do Tailwind. Caixa de marcar solta = `ss-inputs` e base
  (`<summary>` sem marcador, menos movimento) = `ss-base` no `<body>`. Menus `<details>` (`.ss-menu`,
  `.ma-kiosk-pop`): Esc/clique fora no `application.js`.
- Stimulus: comportamento genérico é da gem (`ss-copy`, `ss-filter`, `ss-poll`,
  `ss-reload`, `ss-autosubmit`, `ss-check-all`, `ss-sortable`, `ss-scroll-current` nas faixas de chips, `ss-theme` e
  `ss-privacy` no `<body>`). Os do produto (`controllers/`) são só de domínio:
  câmera/voz, mapa, planta, quiosque, editor de painel, primeira configuração,
  Google/passkey/push. Tema na chave `ss-theme` (o `web/shared/_theme_head` migra a
  antiga `theme` uma vez); "esconder valores" continua na chave `privacy`
  (`data-ss-privacy-key-value`). O `AppScreen` lê `ss-poll`/`ss-reload` como os
  blocos `poll`/`reload` do app.
- Densidade (v0.11): `ss_density_head` no `<head>` dos layouts (junto do
  `_theme_head`) e o `Ss::DensityPickerComponent` em Configurações → Aparência
  (`#densidade`). Como o claro/escuro, é **deste aparelho** (localStorage
  `ss-density`), não do perfil: o tablet da parede pode ser confortável e o
  computador compacto. CSS de tela não fixa altura de controle: usa os tokens
  `--ss-*` da gem (`--ss-control-h`, `--ss-gap`, `--ss-card-pad`…).
- Telas do app: o app lê esta mesma web pelo `AppScreen` (`docs/app.md`); ao mexer
  em markup, rode os `spec/requests/appweb*_spec.rb`.

## Armadilhas

- Comentário `<%# locals: (...) -%>` só pode ter a assinatura: texto depois
  dela vira código e quebra o template.
- ERB `<% case %>` + `<% when %>` em linhas separadas não compila; use if/elsif.
- Componente com bloco de chaves: `render(Ss::XComponent.new(...)) { ... }`. Sem os parênteses
  do `render`, o `{ }` vai para o `.new` e o conteúdo some (o `do … end` não tem esse problema).
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

Push no `master` → quality → imagem `ghcr.io/minhasuite/minha-automacao` e
release beta (o "Atualizar" das instalações lê). O CI não publica em lugar
nenhum: a casa recebe por `bin/deploy-local <tag>` (seção "Servidor local")
ou pelo "Atualizar". Boot com `db:prepare`.
