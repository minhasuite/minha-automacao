# Diário e Histórico (paridade com o Logbook e o History do HA)

**Qual é qual.** O **Diário** responde "o que aconteceu?": uma lista de acontecimentos em texto,
do mais novo para o mais velho (mudou de estado, comando, automação rodou, cena, alerta, cadastro,
entrada), de todo o local, com filtros. O **Histórico** responde "como esse valor andou?": gráficos
de alguns pontos que você escolhe (até 12) na mesma janela de tempo, para comparar (temperatura
com o ar ligado, consumo com a bomba, porta com movimento). Diário = linha do tempo de eventos;
Histórico = séries numéricas e faixas de estado.

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

### Tela do Histórico (paineis-ia, 14/11/2026)

- Período numa faixa só (`ss-chips` + `ss-scroll-current`, rola no celular): **Hoje** (do começo do
  dia no fuso do local até agora), **Ontem** (o dia inteiro), 1 h a 30 dias; ‹ › desloca, aproximar/
  afastar e datas. `Points::Overlay.window` aceita `range=today|yesterday`; `current?` marca o chip.
- `Ss::AsideLayoutComponent`: gráficos no principal; na coluna (no celular, embaixo) os pontos
  escolhidos com cor e valor de agora (tirar um, "Limpar"), **"Comparar de uma vez"** e a escolha
  com busca (nome do ponto, do aparelho e o cômodo, pelo `data-ss-filter-text` do `ss-filter`).
- Sugestões (`Points::Overlay.suggestions`): grupos de 2+ pontos dos aparelhos listados — medida da
  mesma unidade e classe (ou nome) e faixas da mesma capacidade (porta, movimento, presença) —, os
  maiores primeiro, até 12 pontos cada. Sem ponto escolhido, aparecem no estado vazio.
- Cada gráfico (um por unidade, 260 px) tem a legenda com o resumo da janela: agora, mínimo, máximo
  e média (`hx_stats`); linha do tempo das faixas com o nome em cima (`label_position: :top`).
