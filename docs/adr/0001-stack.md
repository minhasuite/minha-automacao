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

**Um servidor só, no local** (ESQUEMA-V1 §3 e §11, revisto em 2026-10-29):
web, API, worker (motor de automação e drivers) e Postgres rodam juntos num
servidor dentro de casa (qualquer Linux com Docker), com acesso externo por
túnel Cloudflare. Sem central/borda, sem MQTT entre eles. A VPS da suíte
serve só para validar UI/UX no desenvolvimento. Imagem multi-arquitetura
(`linux/amd64` + `linux/arm64`).

## Consequências

- Esta base é só a da suíte; o domínio (sites, dispositivos, pontos,
  automações) entra em migrations e ADRs seguintes.
