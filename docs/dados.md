# Conjuntos de dados (Lote 2)

O registro de dados das automações: no lugar do `shell_command ia_db`
(SQLite) e do sensor `sql` do Home Assistant. Serve para histórico de
análises da IA, feedback, contadores e "já avisei hoje".

## Modelo

- `Dataset` (por local): `name`, `key` (do nome), `fields` (opcional,
  `[{name, type}]`, tipos `text`, `number`, `bool`, `time`) e
  `retention_days` (nulo = guarda tudo). Sem campos, aceita qualquer campo
  (nome `a-z0-9_`) e reconhece número em texto.
- `DatasetRecord`: `data` (jsonb), `created_at` e `automation_run_id`.
- Retenção: `Dataset.purge_old!` no `ReadingsMaintenanceJob` (3h).
- Zerar a instalação apaga conjuntos e registros; exportar leva os dois.

## Tela

Aba **Dados** do local (`/locais/:id/dados`): lista com a contagem, cadastro
(técnico ou dono), registros com filtros (os mesmos da ação) e período, e
**Exportar CSV** (até 50 mil linhas, aspas dobradas e texto que começa com
`=`, `+`, `-` ou `@` ganha `'` na frente para não virar fórmula).

## Ações e helper

- **`dataset_record` "Registrar dados"**: `values` = `{campo: texto Liquid}`.
  O conjunto converte pelo tipo; campo desconhecido ou valor que não serve
  para o tipo = erro (o `continue_on_error` vale).
- **`dataset_query` "Consultar dados"**: `op`, `field`, `window`, `filters`,
  `limit`. Resposta `{value}` ou, em `rows`, `{value, rows, count}`, cada
  linha `{id, em, ...campos}`: `{% for r in dados.rows %}` no pedido da IA.
- **Liquid `dataset_rows`** (o sensor `sql` do HA com a lista num atributo):
  `{% assign acoes = "robo_historico" | dataset_rows: 10 %}` dá as linhas mais
  recentes (`{id, em, ...campos}`, `em` no fuso do local; até 50), com os
  filtros da ação no segundo argumento (`dataset_rows: 10, "tipo = erro"`).
  Vale no Texto do painel e nos textos das automações; o card não se refaz
  sozinho a cada linha gravada (refaz ao abrir ou quando um ponto citado muda).
- **Helper "Consulta"** (`dataset_query`): o mesmo com um valor só; vira
  ponto e se refaz a cada linha gravada no conjunto (`docs/helpers.md`).

## Tipos de consulta e filtros como plugins

`Datasets::AGGREGATES` (`app/services/datasets/aggregates.rb`): `count`,
`sum`, `avg`, `min`, `max`, `last` e `rows`. Tipo novo = classe com
`describe key:, label:, field:, scalar:` e `call(scope, field, limit, zone)` +
o nome no registro + spec. O editor, a validação, o helper e a tela perguntam
ao registro.

`Datasets::OPERATORS` (`app/services/datasets/operators.rb`): `=`, `!=`,
`contém`, `>`, `<`, `>=`, `<=`, um filtro por linha (`porta = garagem`,
`minutos > 10`). Com número, só pega campo numérico; com texto (data ISO),
compara como texto. Operador novo = classe com `describe symbol:` e
`apply(scope, field, value)`.

## SQL livre: fora, de propósito

Não há SQL do usuário, nem num modo "somente leitura". O campo entra no SQL
sempre como valor quotado (Arel ou parâmetro), e o SQL de cada operador é
constante da classe. Se faltar uma consulta, ela vira um tipo novo no
registro.
