# Busca global

Uma busca só para a casa inteira: o Ctrl+K da web (`Ss::CommandPaletteComponent`
em `web/shared/_palette`, página `/busca`) e o campo de busca do Início no app
(`GET /api/v1/search`). As duas pontas usam as mesmas fontes e a mesma regra de
papel; o app só desenha.

## O que acha

| Tipo (`kind`/prefixo da chave) | Fonte | Abre | Ação rápida |
|---|---|---|---|
| `page` | `PagesSource` | página do menu | — |
| `setting` | `SettingsSource` (lista do `SettingsNav`, a mesma do menu de Configurações, + palavras de `search.settings_words.<chave>`: "senha" → Segurança) | item de Configurações | — |
| `point` | `PointsSource` (nome, aparelho, área, apelidos; pontos do `Dashboards::Cache.points`) | página do ponto / folha do ponto no app | com verbo: ligar, desligar, alternar (papel x risco, confirmação) |
| `camera` | `CamerasSource` (pontos `stream`) | câmera | — |
| `device` | `DevicesSource` (nome, fabricante, modelo, área, integração; sem os virtuais internos) | aparelho | — |
| `scene` | `ScenesSource` | cena | "ativar cena X" |
| `script` | `ScriptsSource` | editor (técnico+) ou "executar" | "executar script X" (publicado, sem campo obrigatório, papel x risco; crítico com a confirmação) |
| `area` | `AreasSource` | área | — |
| `dashboard` | `DashboardsSource` | painel | — |
| `widget` | `WidgetsSource` (cards dos painéis publicados: rótulo, título ou nome do ponto; respeita `visible_if.role`) | o painel **na visão do card**, com o card em foco (`#id`) | — |
| `dashboard_action` | `DashboardActionsSource` (editor) | revisão/editor | desfazer, duplicar |
| `automation` | `AutomationsSource` (técnico+) | editor | — |
| `integration` | `IntegrationsSource` (técnico+) | integrações do local | — |

**Fonte nova** = classe em `app/services/search/` herdando de `Search::Source`
(`call(q, ctx)` → `[Search::Result]` só do que a pessoa vê; `prefix` + `lookup(id, ctx)`
para entrar nos recentes) + nome em `Search::SOURCES`. Nada de `case` por tipo no
núcleo, na web ou no app: o app abre pelo `target` (ponto e painel nativos) ou pela
`url` (tela do servidor), e executa pelo `action`.

## Ações ("ligar luz da sala")

Verbo no começo (`Search::VERBS`, pt/en/es) vira ação: os pontos que aceitam o
comando, com o papel do local x o risco do ponto (`SiteMembership.allowed?`), e a
confirmação do ponto (`confirm`) ou do risco. "luz/luzes/lâmpada" sai dos termos mas
faz a busca preferir as luzes (regra de nome do painel automático,
`Dashboards::Generator::LIGHT`). Com verbo, o que a pessoa pode executar vem antes. A
web manda o POST das rotas de sempre (`/pontos/:id/comando`, `/cenas/:id/acionar`,
`/automacoes/:id/executar`); o app recebe `action.path`/`body` da API
(`/points/:id/commands` com `client_uuid`, `/scenes/:id/activate`, `/scripts/:id/run`),
e a rota confere o papel de novo.

## Tolerância e ordem

- `Search::Match`: sem acento e sem caixa (`I18n.transliterate`), palavra igual (3),
  começo de palavra (2), dentro (1) e erro de digitação (0,5: Damerau-Levenshtein 1,
  ou 2 em termo de 7+ letras; termo de 4+ letras). Todos os termos precisam bater; o
  título vale 1,5x; nome inteiro igual +2.
- **Por que não pg_trgm/unaccent no Postgres**: as fontes juntam texto de várias
  tabelas e de dentro do JSON dos painéis e do i18n, e a casa tem centenas de itens.
  Os pontos já estão na memória (`Dashboards::Cache.points`); uma busca no banco de dev
  com 500 pontos e 12 visões leva 25–50 ms. Sem migração.
- `Search::Recent`: abrir pela busca guarda o item (`users.dashboard_prefs["search_recent"]`,
  até 15, com o retrato título/ícone/endereço para a paleta não consultar nada); sobe
  na ordem (+3 o último, caindo), junto dos pontos que a pessoa comandou nos últimos 14
  dias (+1) e dos favoritos do painel (+2). Grupos saem pela melhor nota; até 6 por grupo.

## Web

- Paleta (Ctrl+K): Recentes (retrato), Páginas, Experimente e, ao digitar, os grupos
  do servidor (`/busca?paleta=1`). Setas escolhem, Enter abre ou executa, Esc fecha.
- Link de resultado = `GET /busca/abrir?k=<chave>`: relê o item pela fonte (papel de
  agora), guarda nos recentes e redireciona para o endereço que a fonte dá (o pedido
  nunca escolhe o endereço).

## API (app)

- `GET /api/v1/search?q=` → `data` = itens em ordem, `meta` = `{q, groups: [{kind, label}]}`.
  Sem `q`: os recentes. Item: `{key, kind, group, title, subtitle, icon, url, target, action, recent, favorite}`;
  `target` = `{type: "point", id, site_id}` ou `{type: "dashboard", id, site_id, view?, widget_id?}`;
  `action` = `{label, method: "POST", path, body, confirm, confirm_title}`.
- `POST /api/v1/search/recent {key}` → 204 (404 se não existe ou não vê).
