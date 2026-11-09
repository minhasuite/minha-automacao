# Fila e jobs

Configurações → **Fila** (`GET /configuracoes/fila`) e `GET /api/v1/system/queue`.
Só o **dono**, numa instalação só (`QueueMonitor.visible_to?` = a regra dos
Logs): o Solid Queue é do servidor inteiro. Os outros levam 404 na web e 403
na API; chave de integração não entra. A tela se recarrega com morph a cada
10 s (`ss-reload`). Tudo sai do `QueueMonitor` (`app/services/queue_monitor.rb`).

## O que mostra

- **Agora**: pendentes (`ready_executions`, com a espera do mais antigo), em
  execução (`claimed_executions`), agendados, com erro, concluídos em 24 h e
  processos vivos (heartbeat dentro de `SolidQueue.process_alive_threshold`).
- **Latência dos comandos** (última hora e 24 h, total e por driver), p50, p95
  e máximo de:
  - **fila** = `sent_at − created_at` (pedido → o `ExecuteCommandJob` começou);
  - **aparelho** = `confirmed_at − sent_at` (o driver mandou → confirmou).

  Fila alta = o atraso é do servidor (worker ocupado, polling, HDD); aparelho
  alto = rede ou aparelho. Mais os últimos 50 comandos com os dois tempos e
  as falhas/expirados das 24 h com o erro.
- **Jobs nas últimas 24 h** por classe: concluídos, falhas, média/p95/máximo de
  **espera + execução** (`finished_at − scheduled_at`). O Solid Queue não guarda
  quando o job começou; a espera separada só existe para quem está rodando
  (`claimed_executions.created_at − scheduled_at`) e, nos comandos, acima.
- **Abas** (até 50 linhas cada): Em execução (desde, esperou, processo),
  Agendados, Com erro (classe, mensagem, 5 linhas do backtrace, **Tentar de
  novo** = `FailedExecution#retry`, **Descartar** = `#discard`) e Concluídos.
- **Processos** e **tarefas recorrentes** (última pelo `recurring_executions`,
  próxima pelo `RecurringTask#next_time`).

## Custo

Contagens nas tabelas de execução (pequenas), `solid_queue_jobs` pelo índice de
`finished_at` (os concluídos somem depois de 1 dia), comandos pelo índice
`(tenant_id, created_at)` (migração `20261108100001`) e sempre com LIMIT.

## API

`GET /api/v1/system/queue` → `{data: {summary, command_latency: {"1h"|"24h":
{total, drivers[]}}, processes, recurring, jobs}, meta: {generated_at, windows,
unit: "s"}}`. Latência: `{count, failed, expired, queue: {p50, p95, max},
device: {p50, p95, max}}` em segundos (nil sem dado). O app ainda não usa.
