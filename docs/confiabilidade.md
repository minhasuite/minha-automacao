# Confiabilidade

O que o servidor faz sozinho quando a rede, um aparelho ou o próprio worker
falham. Código: `Transient`, `Reliability`, `Automations::Sweeper`,
`Alexa::Throttle`, `Health::Checks::Reliability`.

## Nova tentativa só quando nada saiu (`Transient`)

`Transient.retryable?(erro, strict:)` olha o erro e a cadeia de `cause` (os
clientes embrulham o erro de rede no deles):

| Tipo | Exemplos | Repete? |
|---|---|---|
| conexão que nem abriu (`:connect`) | `Net::OpenTimeout`, `ECONNREFUSED`, `EHOSTUNREACH`/`ENETUNREACH`, DNS (`SocketError`), TLS no `SSL_connect`, erro com `Transient::NotSent` (`Tuya::Connection::ConnectError`) | sim, inclusive ponto crítico |
| recusa sem efeito (`:busy`) | HTTP 429/502/503/504 em erro com `Transient::Busy` (`Alexa::Client::Busy`, `Tuya::Cloud::Busy`; FCM e Web Push) | sim, menos ponto crítico (`risk: critical`: portão, sirene, fechadura) |
| o resto | `Net::ReadTimeout` (o pedido pode ter chegado), conexão que caiu no meio, recusa do aparelho, erro desconhecido | **nunca** |

- **Comandos** (`ExecuteCommandJob`): falha repetível volta o comando a
  `pending` (erro "Tentativa N falhou: …", `commands.attempts`) e o job se
  reagenda em 5 s, 30 s, 2 min (ou o `Retry-After`), **nunca além do
  `Command::TTL`** (1 min desde a criação). Na prática são até 3 tentativas.
  Nova tentativa que chega tarde à fila vira `failed` ("prazo esgotado").
- **Push** (`SendPushJob`): cada transporte devolve os aparelhos em que nada
  chegou (`deliver_some`); só eles recebem nova tentativa (5 s, 30 s, 2 min).
- **Nuvem** (Tuya `Tuya::Cloud.http`, Xiaomi `Miio::Cloud#request`): conexão que
  não abriu tenta mais uma vez na hora (`Transient.with_retry`); o comando
  ainda tem a nova tentativa do job.

## Alexa: um anúncio por conta e ritmo

- Aviso ou ação "Falar" para vários `alexa:<ponto>` da mesma conta (integração +
  cliente da Amazon) = **um** `announce` com todas as Echo
  (`Points::Command.call_group`). A trilha continua com um comando por Echo:
  todos com o mesmo `batch_id` (= id do líder); o líder executa
  (`Drivers::Alexa#execute_group`) e os outros copiam o status dele.
- `Alexa::Throttle`: pedidos da mesma conta saem com 1,5 s entre eles; um 429
  segura a conta pelo `Retry-After` e o comando volta à fila (dentro do TTL).
  Recusa passageira não deixa a integração "Com erro".

## Aparelho sem sinal

`Reliability.signal_lost(device)`: status `offline`/`error` (leitura periódica,
ouvintes) **ou** os últimos 3 comandos falharam, e o último contato (visto ou
comando confirmado) passou do limite. Limite por instalação:
`tenants.settings["reliability"]["dead_device_hours"]` (padrão 24).

- Comando de **automação** (`source: "automation"`: automações, cenas,
  agendas, avisos na Echo…) não chama o driver: vira `skipped` com
  "Aparelho sem sinal há X: comando não enviado." e passo pulado no trace (a
  execução segue).
- Comando de **pessoa** (web, app, voz, Alexa) sempre tenta: é por ele (ou pela
  leitura periódica) que o aparelho volta.

## Execuções sem dono (`Automations::Sweeper`)

`AutomationSweepJob` no início do worker (2 min depois, fecha o que rodava
antes do início) e a cada 5 min (`config/recurring.yml`, bloco
"confiabilidade"):

- `running` sem atualizar há `run_max_minutes` (padrão 15) → `interrupted`
  (passo no trace); a próxima da fila (`queued`) começa; ramo de "Em paralelo"
  avisa o pai (que falha).
- `waiting` com `resume_at` vencido há mais de 2 min: retoma
  (`AutomationResumeJob`) se o atraso é menor que `run_max_minutes`; se é
  maior, fecha como `interrupted` em vez de agir fora de hora.

## Avisos de falha repetida (Saúde)

Verificação **Confiabilidade** (Configurações → Saúde): aparelhos sem sinal
(só informa), ponto com 3 comandos seguidos falhando, automação com 3
execuções seguidas falhando/interrompidas e pico de comandos com falha (≥ 10
na última hora). Itens com erro viram aviso (app + push) pelo `HealthCheckJob`,
um por problema por dia (`dedup_key`). `failure_streak` muda o 3.

A fila parada (tarefa pronta esperando > 5 min, trabalhador sem sinal) não
pode ser avisada pelo próprio worker: o `Reliability::Watchdog` roda numa
thread do supervisor do Solid Queue (`SolidQueue.on_start`,
`RELIABILITY_WATCHDOG=off` desliga), olha a verificação "Fila de tarefas" a
cada minuto e manda o aviso com o push na hora.

## Estado real dos sensores

Sensor de porta, movimento e afins só fala quando muda: evento perdido deixa o
ponto preso num valor que já passou (10/11/2026: o "fechou" do portão nunca
chegou e o escalonamento avisou por horas).

- **Conferência da nuvem Tuya**: com o MQTT da conta conectado, o
  `Tuya::CloudListener` relê o estado de todos os aparelhos a cada
  `RECONCILE_EVERY` (10 min, 2 pedidos). Corrige o evento que se perdeu entre a
  nuvem e o servidor; erro na conferência não derruba o tempo real.
- **Redefinir estado** (página do ponto, técnico+; `POST /api/v1/points/:id/reset`):
  ponto que não recebe comando (contato, movimento, violação, problema, enum,
  medição) ganha o valor informado pelo `report!` (automações e alertas veem a
  mudança) e um `AuditEvent` `reset` na linha do tempo. Até o aparelho empurrar
  um evento, a releitura do estado completo (conferência, conexão curta) não
  desfaz a correção (`address.reset_at`, `Points::Reset.held?`).
- **Desatualizado**: com "Desatualizado se aberto há mais de (min)" no
  formulário do ponto (`address.stale_open_s`), o `Points::Stale.tick`
  (RunSchedulesJob) põe a qualidade `stale` no sensor aberto além do limite e
  manda **um** aviso (`dedup_key` por abertura). Releitura com o mesmo valor
  mantém o "desatualizado"; valor novo ou "Redefinir estado" volta a "Bom".
  Escalonamento que não deve insistir num estado em que ninguém confia usa a
  condição "Ponto está" com a situação "Bom".
