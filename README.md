# Minha Automação

Servidor de automação da MinhaSuite para casa, loja e indústria: **central** (VPS, multi-tenant) e **borda** (qualquer
Linux com Docker, `EDGE=1`). Rails 8.1, mesma base de código nos dois modos.

Proposta e esquema: `../docs/PROPOSTA.md` e `../docs/ESQUEMA-V1.md` (workspace `minha-automacao-workspace`).

## Desenvolvimento

Ruby só em container. Guia em `docs/DEV_ENV.md` (Postgres `127.0.0.1:6299`, app `:4121`, login de teste
`teste@teste.com` / `12345678`); regras e armadilhas do repo em `CLAUDE.md`.
