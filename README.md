# Minha Automação

Servidor de automação da MinhaSuite para casa, loja e indústria. Roda inteiro num servidor local (qualquer Linux com
Docker), com acesso externo por túnel Cloudflare, como o Home Assistant. Rails 8.1.

Proposta e esquema: `../docs/PROPOSTA.md` e `../docs/ESQUEMA-V1.md` (workspace `minha-automacao-workspace`).

## Desenvolvimento

Ruby só em container. Guia em `docs/DEV_ENV.md` (Postgres `127.0.0.1:6299`, app `:4121`, login de teste
`teste@teste.com` / `12345678`); regras e armadilhas do repo em `CLAUDE.md`.

## Licença

Código aberto sob a [Apache License 2.0](LICENSE). Use, modifique e distribua à vontade,
inclusive comercialmente, mantendo o aviso de licença.
