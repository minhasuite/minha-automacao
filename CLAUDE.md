# minha-automacao — guia rápido

Monolito Rails 8.1: web (Hotwire) **e** API `/api/v1` do app Flutter
`minha-automacao-app`, no mesmo processo. É o servidor de automação da
MinhaSuite (casa, loja e fábrica), no lugar do Home Assistant. Produto em
`../docs/PROPOSTA.md`; modelo de dados, DSL, API e decisões em
`../docs/ESQUEMA-V1.md`; stack em `docs/adr/0001-stack.md`. O padrão da suíte
está na skill `padrao-suite`; aqui só o que é deste repo.

**Estado:** base da suíte (empresa, usuários, auth da API, convites, push,
notificações, assinatura, IA, licenças, telemetria, páginas legais e conta) +
**F1**: locais, áreas, papéis por local, dispositivos, pontos, etiquetas (só
modelo) e comando síncrono no driver `virtual` (`Points::Command`), na web
(`/locais`) e na API. Histórico, comandos rastreados, borda, drivers,
automações e dashboards ainda não existem.

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

## Deploy

Push no `master` → quality → imagem `ghcr.io/minhasuite/minha-automacao`. O
deploy em `/opt/minha-automacao` (`ms-minha-automacao-{web,worker}`) roda no
CI (`deploy-prod`) e avisa o meulog; produção em
`https://minhaautomacao.minhasuite.com`. Boot com `db:prepare`. Na VPS as variáveis são `MINHA_AUTOMACAO_*`; no
container, nome curto.
