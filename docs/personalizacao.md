# Personalização por dado (P3: fora dos painéis)

Três coisas que eram código passaram a ser dado da casa, sem tocar no repo.
Proposta: `../docs/PROPOSTA-personalizacao.md`, seção "P3 — Fora dos painéis".
Nada roda código do usuário: consultas só pelo `Points::Query`, expressões só
pela calculadora das automações (`Automations::Expr`, dentaku) e textos só em
Liquid com os filtros registrados no `Automations::Context` (limite de tamanho).

## Verificação personalizada da Saúde

Configurações → Saúde → **Verificações personalizadas**
(`/configuracoes/saude/verificacoes`, só administradores). Cada registro
(`CustomHealthCheck`, por local) tem:

| Campo | O que é |
|---|---|
| `query` | Consulta de pontos (`quality=unavailable tag=bateria`). Sozinha: problema quando acha algum ponto. |
| `expression` | Expressão da calculadora (`count_points("quality=unavailable") > 0`, `sala.temperatura > 30`, `hour`, `weekday`). Verdadeira = problema. Com a consulta junto, `count` é quantos ela achou. |
| `severity` | `warn` (só na tela) ou `error` (também o aviso diário). |
| `message` | Texto em Liquid com `count`, `found` (os pontos da consulta, até 20, com `name`, `text`, `quality`...) e o contexto das automações. Vazio = os nomes dos pontos. |

Entram na Saúde pela verificação `Health::Checks::Custom` (`custom` em
`Health::CHECKS`): um item por registro ligado, com "Editar verificação" como
reparo guiado. O `HealthCheckJob` avisa o item com erro uma vez por dia, com o
mesmo `dedup_key` das outras (`saude:<tenant>:custom:<id>:<dia>`); ignorar
funciona como nas outras. Consulta ou expressão quebrada vira item em atenção
com o erro, sem derrubar os outros. "Ver prévia" roda com o que está no
formulário, sem salvar.

API (administradores): `GET /api/v1/health` (todas as verificações e itens),
`GET/POST /api/v1/health_checks`, `GET/PATCH/DELETE /api/v1/health_checks/:id`
(o `GET` de um traz `result`) e `POST /api/v1/health_checks/preview`
`{site_id, query, expression, severity, message}` → `{problem, status, count, detail}`.

## Texto dos avisos e alertas

O Aviso (`NotifyRule#message`) e o Alerta (`AlertRule#message`, novo: o
corpo do aviso de cada etapa) aceitam Liquid com o mesmo contexto do Texto do
painel e das automações (`MessageTemplate`, por cima do `Automations::Context`):

- `{{ trigger.point }}` (nome), `{{ trigger.key }}`, `{{ trigger.value }}`,
  `{{ trigger.text }}` (valor formatado), `{{ trigger.point_id }}`;
- só no alerta: `{{ trigger.alert }}` (nome da regra), `{{ trigger.minutes }}`,
  `{{ trigger.severity }}`;
- `{{ points["sala.luz"].text }}`, `{{ "quality=unavailable" | points_where | size }}`,
  `{{ "hour * 60" | calc }}`, `{{ now | date: "%H:%M" }}`, `{{ site.name }}`.

`{ponto}` e `{valor}` continuam valendo. Até 1000 caracteres; Liquid inválido
não salva. Texto que falha na hora de avisar (ponto que sumiu) não cala o
aviso: vai o texto padrão. Antes, a mensagem do aviso só trocava `{ponto}` e
`{valor}` e o alerta não tinha texto próprio.

Prévia: botão "Ver prévia" nos formulários (manda `preview=1` para o mesmo
create/update; volta a tela com o resultado, sem salvar; funciona igual no
app pelo AppScreen). Na API: `POST /api/v1/sites/:id/message_preview
{template, point_id?}` → `{text}` (técnico ou dono do local); `message` nos
campos de `alert_rules`.

## Voz: frases e respostas da casa

Local → Assistente de voz → aba **Da casa** (técnico ou dono).

- **Frases da casa** (`AssistCustomIntent`): nome, idioma (vazio = qualquer),
  frases-modelo no formato do HA (uma por linha: `[opcional]`, `(a|b)`,
  `{slot}`), alvo (uma cena ou um script do local) e a resposta (`{slot}`
  trocado; vazia, ou com slot que a frase não trouxe = "Feito: <nome>.").
  Reconhecidas pela intenção `custom` (`Assist::Intents::Custom`), logo
  depois das frases das automações e antes das nativas. Comando com o papel x
  risco de quem fala, `source: "voice"`, dentro do `Shadow.for_site`; **cena ou
  script crítico nunca**: a validação recusa e a execução confere de novo.
- **Respostas da casa** (`AssistCustomResponse`): troca um texto de resposta
  de uma intenção do registro (`ref` = `intenção.chave`, como `turn_on.done`)
  ou um comum da base (`*.denied_only`, `*.failed`...), por idioma. `{names}`
  ou `%{names}` (e as outras variáveis da resposta padrão) continuam valendo.
  O `Assist::Intent.text` procura a do local da conversa (`Assist.with_site`,
  ligado no `Assist.call` e no MCP): a da intenção ganha da "*", a do idioma
  ganha da "qualquer".

API: `/api/v1/sites/:id/assist/intents` e `/api/v1/assist/intents/:id`
(`sentences` em lista, `target` = `scene:<id>` ou `script:<id do ponto>`);
`/api/v1/sites/:id/assist/responses` (a lista traz `meta.choices` com o que dá
para trocar e o texto padrão) e `/api/v1/assist/responses/:id` (`ref`,
`language`, `text`). Ver: qualquer papel; mudar: técnico ou dono.

## Tabelas

`custom_health_checks`, `assist_custom_intents`, `assist_custom_responses`
(todas com `tenant_id`/`site_id`, em `Accounts::WipeData::MODELS` e no
`Accounts::ExportData`) e a coluna `alert_rules.message`.
