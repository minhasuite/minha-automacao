# Diário e Histórico (paridade com o Logbook e o History do HA)

## Diário (`/diario`, `GET /api/v1/sites/:id/logbook`)

Linha do tempo de tudo o que aconteceu num local, do mais novo para o mais
velho, agrupada por dia. Fontes por registro (`Logbook::SOURCES`):

| Fonte | O que mostra | Papel |
|---|---|---|
| `changes` | mudança de valor de ponto que não é medida (liga/desliga, aberto, estado, zona da pessoa), pelas `readings` | qualquer |
| `commands` | comandos (pessoa, automação, Alexa, voz) e como terminaram | qualquer |
| `runs` | execuções de automação e de script (status, sombra, erro) | qualquer |
| `scenes` | cena acionada (evento `scene` gravado pelo `Scene#activate!`) | qualquer |
| `alerts` | alerta abriu, ciente (de quem) e fechou | qualquer |
| `quality` | ponto sem sinal, com erro ou de volta | qualquer |
| `audit` | cadastro criado, alterado ou excluído (AuditEvent do que é do local) | técnico+ |
| `logins` | entradas na web e no app (AuditEvent `login`) das pessoas do local | dono |

Filtros: período (24 h, 7 dias, 30 dias, 1 ano ou datas), área, dispositivo,
ponto, pessoa, tipo (fonte) e busca (nome ou chave do ponto, aparelho,
automação, cena). Rolagem infinita: cada página termina num `turbo-frame`
preguiçoso com o cursor `before` (o `at` do último item). Na API, o mesmo
filtro, `limit` (até 200) e `meta.next_before`.

Fonte nova = classe em `Logbook::Sources` (herda de `Base`: `describe key:,
label:, icon:, role:` e `fetch(f)` → itens `item(at:, title:, state:, tone:,
detail:, user:, point_id:, ref:)` com `at` em `f.window`, no máximo
`f.limit`, filtrando por `f.points`, `f.user_id` e `f.q` quando fizer
sentido) + nome em `SOURCES`. Spec com `stub_const` em
`spec/requests/paridade_diario_spec.rb`.

## Histórico (`/historico`, `GET /api/v1/sites/:id/history`)

Até 12 pontos na mesma janela (`Points::Overlay`): número vira linha (um
gráfico por unidade, linhas sobrepostas, faixa mín–máx quando é por hora ou
dia) e o resto vira faixas na linha do tempo (um trecho por valor, com o
texto e o horário). Janela: atalhos (1 h a 30 dias), datas, deslocar,
aproximar/afastar e arrastar no gráfico (mouse) para aproximar; cursor com
os valores de cada série. Resolução pelo `Points::History` (cru até 2 dias,
por hora até 31, por dia depois). **Exportar CSV** (`;`, vírgula decimal):
ponto, chave, unidade, início, fim, valor, mínimo, máximo.
