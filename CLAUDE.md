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
ponto, `/locais/:id/automacao`, `/alertas`) e na API. Automações (DSL) e
dashboards ainda não existem.

## Rodar

```bash
docker compose -f .devcontainer/docker-compose.yml up -d     # pg 127.0.0.1:6299, app :4121
docker compose -f .devcontainer/docker-compose.yml exec -T app bash -c \
  'cd /app && bundle exec rspec && bundle exec rubocop --parallel && bundle exec brakeman -q'
```

`bash -c`, não `bash -lc`. Detalhes em `docs/DEV_ENV.md`. Seeds:
`bin/rails db:seed` (matriz de IA, flags e, só em dev, `teste@teste.com` /
`12345678`). Web: `bin/rails tailwindcss:build` antes de abrir a tela ou
rodar spec que renderiza layout. Cobertura mínima 70%.

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
- **Convite** por código (sem e-mail): `Invite.generate!` mostra o código uma
  vez; entrar com ele (`Companies::Join`) tira a pessoa da empresa atual. Se
  ela era a única e a empresa tem dados (`Accounts::WipeData::MODELS`), exige
  `discard_current`.
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
- Nunca acione de teste portão, sirene, ar-condicionado, irrigação ou
  bomba/filtro da piscina; leitura de estado pode.

## Servidor local (casa)

Debian `192.168.68.199` (`ssh -i ~/.ssh/dell_automacao herlon@…`), em
`/opt/minha-automacao`: `docker-compose.yml` (= `docker-compose.local.yml`),
`.env` (chmod 600, segredos gerados lá; nunca no repo), `backups/` (pg_dump
diário, 7 dias). `bin/deploy-local [tag]` no WSL: usa a imagem local do
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
