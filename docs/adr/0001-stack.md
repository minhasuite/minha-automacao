# ADR 0001 — Stack do Minha Automação

Data: 29/10/2026 · Situação: aceita

## Contexto

Servidor de automação da MinhaSuite para casa, loja e fábrica, no lugar do
Home Assistant (`../../docs/PROPOSTA.md`): dispositivos, pontos, automações,
cenas, alertas, dashboards, histórico e integração com os outros produtos da
suíte, com app Flutter nativo.

## Decisão

A mesma stack dos outros produtos da suíte (skill `padrao-suite`).

| Camada | Escolha |
|---|---|
| Backend | Rails 8.1, monolito web (Hotwire + Tailwind, Lista Clara) + API `/api/v1` |
| Banco | Postgres 18 (`minha_automacao_prod` no `ms-postgres`), UUID em toda tabela |
| Fila / cache / tempo real | Solid Queue (`recurring.yml`), Solid Cache, Solid Cable, sem Redis |
| Multi-tenant | `acts_as_tenant` com `require_tenant = true`, modelo `Tenant` |
| Auth | `ApiToken` (access 30 min + refresh 60 dias rotacionado), `ServiceApiKey` com escopos, sessão em cookie no web |
| App | Flutter (Riverpod, Dio, go_router, secure storage, Lista Clara) |
| IA | `Ai::Client` + `Ai::Policy` (cota por plano), nunca no caminho principal |
| Push | FCM (`Notifier` → `SendPushJob`) |
| Planos | `Billing::Entitlement` + Google Play + licenciamento central |
| Telemetria | meulog (`lib/meu_log.rb`, `MeuLogInstrumented`) |

**Dois modos de execução, uma base de código** (ESQUEMA-V1 §3 e §11): a
**central** roda na VPS da suíte (multi-tenant, Postgres, cadastro,
dashboards, histórico consolidado, API do app, integrações) e a **borda**
roda em qualquer Linux com Docker no local (`EDGE=1`, SQLite, motor de
automação e drivers, buffer offline), ligada à central por MQTT de saída.
Imagem multi-arquitetura (`linux/amd64` + `linux/arm64`).

## Consequências

- Esta base é só a da suíte; o domínio (sites, dispositivos, pontos,
  automações, borda) entra em migrations e ADRs seguintes.
- Todo código novo precisa funcionar nos dois modos ou ser explicitamente
  de um só (por exemplo, billing só na central).
