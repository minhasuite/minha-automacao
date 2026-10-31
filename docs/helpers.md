# Helpers (F8e)

Como os helpers do HA: valores seus, sem aparelho, para usar nas automações e
nos painéis. Ficam em `/locais/:id/helpers` (aba "Helpers" do local): lista
com busca, filtro por tipo e o valor atual, que muda ali mesmo (chave, slider,
seleção, campo, botões de ação). "Criar helper" abre o catálogo de tipos.

## Modelo

Um helper **é um ponto**: `points.helper` = chave do tipo, configuração em
`points.address`, valor em `points.value`. Todos ficam no dispositivo virtual
"Helpers" do local (`driver: virtual`, `external_id: "helpers"`, criado
sozinho e fora da lista de dispositivos). Por ser ponto, histórico, painéis,
automações, espelhamento, avisos, alertas, cenas e API funcionam sem código
novo. Comum a todos: nome, ícone (os de `app/assets/images/icons`), área
opcional e `address.restore` ("restaurar o valor depois de reiniciar",
padrão sim; não = volta ao inicial quando o worker sobe, `HelperTypes.boot!`).

## Tipos

| Chave | Tipo | Capacidade | Configuração (`address` e colunas) | Comandos |
| --- | --- | --- | --- | --- |
| `toggle` | Liga/desliga | `onoff` | `initial` | on, off, toggle |
| `number` | Número | `setpoint` | `min`, `max`, `step`, `unit`, `mode` (`slider`/`box`) | set (na faixa e no passo) |
| `select` | Lista de opções | `enum` | `options` (a primeira é a inicial) | select |
| `text` | Texto | `text` | `min`/`max` (tamanho), `pattern` (regex, 0,1 s de limite), `password` | set |
| `datetime` | Data e hora | `datetime` | `mode` (`datetime`/`date`/`time`); valor `2026-10-30T18:30`, `2026-10-30` ou `18:30` | set |
| `button` | Botão | `command` | — (valor = hora do aperto) | press |
| `counter` | Contador | `counter` | `initial`, `step`, `min`/`max` opcionais (passa do limite = fica no limite) | increment, decrement, reset, set |
| `timer` | Temporizador | `timer` | `duration_s`; contando: `finishes_at`; pausado: `remaining_s` | start (valor opcional "5m"), pause, cancel, finish |
| `group` | Grupo | a dos membros (`measure` para números) | `sources` (membros do mesmo tipo), `mode`: `any`/`all` ou `mean`/`median`/`min`/`max`/`sum` | on, off, toggle (só grupo de liga/desliga; repassa a cada membro) |
| `template` | Sensor calculado | `measure`, `onoff` (só leitura), `text` ou `datetime` | `kind` (`number`/`bool`/`text`/`timestamp`), `expr`, `sources` (pontos cuja chave aparece), `every?` (segundos), `attrs?` ({nome: Liquid}) | — |
| `statistics` | Estatística | `measure` | `sources` (um ponto numérico), `func` (`mean`/`median`/`min`/`max`/`sum`), `window_s` | — |
| `dataset_query` | Consulta (Lote 2) | `measure` (`text` no último valor de campo de texto) | `sources` (o conjunto de dados), `op` (tipo de consulta de um valor só), `field`, `window_s`, `filters` | — |
| `utility_meter` | Medidor por ciclo (Pacote 2) | `measure` | `sources` (ponto acumulador), `cycle` (`none`/`hour`/`day`/`week`/`month`/`quarter`/`year`/`cron`), `day` (fechamento, 1 a 28), `cron?`; tarifas em `options` | reset (zerar o ciclo), select (trocar a tarifa) |
| `integral` | Integral (Pacote 2) | `measure` | `sources`, `method` (`trapezoidal`/`left`/`right`), `prefix` (""/k/M/G), `time_unit` (s/min/h/d), `round`, `max_s?` | — |
| `derivative` | Derivada (Pacote 2) | `measure` | `sources`, `prefix`, `time_unit`, `round`, `window_s` (0 = entre as duas últimas leituras) | — |
| `threshold` | Limite (Pacote 2) | `onoff` (só leitura) | `sources`, `lower?`, `upper?`, `hysteresis` | — |
| `trend` | Tendência (Pacote 2) | `onoff` (só leitura) | `sources`, `window_s`, `min_samples`, `max_samples`, `min_gradient` (por segundo), `invert` | — |

- **Temporizador**: valor `idle` (Parado), `active` (Contando), `paused`
  (Pausado) ou `finished` (Terminou). O fim é um `HelperTimerJob` agendado no
  Solid Queue com o carimbo `finishes_at`, como as esperas da F6: sobrevive a
  reinício e job velho (pausou, cancelou, reiniciou) não faz nada.
- **Grupo**: o valor se refaz quando um membro muda (membros fora do ar não
  contam; todos fora = indisponível). O risco é o maior dos membros. Comando
  no grupo vira um `Points::Command` em cada membro, com a origem (web,
  app/API, automação) e a execução do comando do grupo; aparelho de verdade
  vai pela fila, como sempre. Grupo dentro de grupo não pode.
- **Sensor calculado**: número e liga/desliga pela calculadora das automações
  (dentaku: `sala.temperatura - externo.temperatura`, `if()`, `round()`);
  texto pelo Liquid delas (`{{ points["sala.luz"].text }}`). Erro na conta =
  qualidade "Com erro". Lote 5 (G9): `previous` é o próprio valor de antes
  (acumulador: `previous + casa.kwh * 0.9`); "a cada" (`every`) refaz pelo
  relógio em vez de quando a origem muda; "Data e hora" aceita segundos
  (`timestamp + 3600`) ou texto e grava "AAAA-MM-DDTHH:MM"; atributos (uma
  linha por atributo, "nome: texto Liquid") vão para `points.attrs`, lidos no
  Liquid (`points["k"].attrs.nome`), na expressão (`k.attrs.nome`) e no
  widget Número (campo Atributo).
- **Estatística**: leituras do histórico da janela; sem leitura, o valor
  atual. Só se refaz quando a origem muda (numa janela parada o valor velho
  não sai sozinho).
- **Consulta** (Lote 2, o sensor `sql` do HA sem SQL): `Datasets::Query` no
  conjunto de dados (`docs/dados.md`). Refaz a cada linha gravada no conjunto
  (a mesma `address.sources`, com o id do conjunto); erro = "Com erro",
  conjunto excluído = indisponível.

### Pacote 2: helpers de medição (como os do HA)

Valem para todos: a origem é um ponto numérico do local; o estado interno
do cálculo (último valor da origem, amostras, total sem arredondar) fica em
`address.state`, gravado sem disparar nada, e o que a pessoa usa vai para o
valor e para os atributos (`points.attrs`: Liquid `points["k"].attrs.x`,
expressão `k.attrs.x`, widget Número). Origem que só muda de qualidade
(caiu, voltou) também refaz o helper (`Point#report!` →
`HelperTypes.on_change`). Trocar a origem no formulário zera o estado.

- **Medidor por ciclo** (`utility_meter`): valor = consumo do ciclo. O ciclo
  vira cron no fuso do local (`Fugit`, "0 0 12 * *" = mensal no dia 12);
  `tick` a cada minuto fecha o ciclo: valor → atributo `last_period`, zera,
  `period_start` novo. Origem que desce (aparelho reiniciou e zerou) = a
  leitura nova inteira é consumo; fora do ar não conta e, na volta, a
  diferença entra de uma vez. Tarifas: lista em `options`; atributo `tariff`
  (a ativa, começa na primeira) e `tariffs` ({tarifa → consumo do ciclo}).
  "Trocar a tarifa" lê a origem antes, então o que andou até ali fica na
  tarifa anterior. "Zerar o ciclo" guarda o valor em `last_period`. O valor
  não se escreve de fora (`POST /value` = 422).
- **Integral** (`integral`): soma de Riemann sobre o tempo; W com prefixo k e
  hora = kWh (unidade montada: prefixo + unidade da origem + tempo). O tempo
  com a origem fora do ar não entra. "Intervalo máximo sem leitura": origem
  parada esse tempo = o `tick` integra assim mesmo com o valor atual.
- **Derivada** (`derivative`): (último − primeiro) / tempo na janela (sem
  janela, entre as duas últimas leituras; leituras mais espaçadas que a
  janela = as duas últimas). Unidade `<prefixo><unidade>/<tempo>`. Sem duas
  amostras = vazio.
- **Limite** (`threshold`): como o HA; só inferior = liga abaixo, só
  superior = liga acima, os dois = liga na faixa; a histerese segura o estado
  perto do limite. Atributo `position` (`below`/`above`/`in_range`). Origem
  fora do ar = indisponível.
- **Tendência** (`trend`): inclinação por mínimos quadrados das amostras da
  janela (até `max_samples`), em unidades por segundo; liga acima de
  `min_gradient` (invertido: abaixo de `-min_gradient`). Menos que
  `min_samples` = indisponível. Atributos `gradient` e `samples`.
- **Mín/máx/média/mediana/soma de vários pontos**: é o Grupo de números
  (`group`, modo `median` novo); a mediana também entrou na Estatística.

Tudo é ponto: entra nas leituras e nos rollups, é gatilho ("Ponto mudou",
"Ponto entre limites", atributo) e condição nas automações e aparece nos
widgets, sem código novo. Tipo que precisa do relógio declara `clocked?` e
`tick(point, now)` (chamado pelo `HelperTypes.tick` a cada minuto). Spec em
`spec/services/pacote2_helpers_spec.rb` (inclui um tipo falso com relógio
registrado por `stub_const`).

## Automações, painéis e API

- **Gatilho**: "Ponto mudou" no helper (de/para opcionais). Botão: sem
  de/para, dispara a cada aperto. Temporizador terminou: para "Terminou".
- **Condição**: "Ponto está" / "Ponto entre limites" / expressão, como
  qualquer ponto.
- **Ação**: "Comandar ponto"; o editor lista os comandos do plugin com os
  rótulos dele (Incrementar, Iniciar temporizador...).
- **Painéis**: o `tile` desenha pela capacidade e pelos comandos do ponto:
  chave, slider ou caixa de número (`mode: box`), seleção, campo de texto/
  data/hora (`input` do ponto resolvido), botão, e botões de ação (`actions`:
  contador e temporizador). Nada de widget por tipo de helper.
- **API**: `GET /api/v1/sites/:id/helpers` (`?type=`; chave com `read`),
  `GET /points/:id`, `POST /points/:id/commands` (papel x risco, chave com
  `command`) e `POST /points/:id/value` (chave com `write`; validado pelo
  plugin, `422` se não serve). O ponto leva `helper` no JSON.

## Tipo novo (aberto para extensão)

1. Classe em `app/services/helper_types/<nome>.rb`, subclasse de
   `HelperTypes::Plugin`, com `describe key:, title:, icon:, description:,
   capability:` e `fields` (os campos do formulário, para o `permit`).
2. Uma linha em `HelperTypes::PLUGINS` (a ordem é a do catálogo).
3. Partial `app/views/web/site_helpers/forms/_<key>.html.erb` com os campos
   (`locals: (f:, point:)`).
4. Sobrescreva só o que precisar:

| Método | Para quê |
| --- | --- |
| `assign(point, form)` | formulário → colunas e `address`; erro em `point.errors` |
| `initial_value(point)` | valor ao criar e ao reiniciar sem "restaurar" |
| `commands(point)` / `command_labels` | comandos aceitos (padrão: os da capacidade) e rótulos no editor |
| `new_value(cmd)` | valor do comando (`cmd.point`, `cmd.command`, `cmd.value`; `cmd.by_capability` = regra da capacidade); recuse com `invalid!` |
| `execute(point, command, value)` | efeito além do valor (agendar, repassar) |
| `actions(point)` | comandos sem valor que a tela mostra como botões agora |
| `value_text(point)` | texto do valor na tela |
| `sourced?` / `refresh!(point)` | calculado: `address["sources"]` + recálculo quando uma origem muda |
| `reset!(point)` | reinício sem "restaurar" |
| `summary(point)` | resumo da configuração na lista |

Nada fora do plugin pergunta o tipo: telas e motor usam
`Points::Command.commands_for`/`actions_for`, `point.helper_type` e a
capacidade. Capacidade nova (como `counter`, `timer`, `datetime`) entra em
`Point::CAPABILITIES` e, se tiver tela própria, no `tile` pela capacidade.
Spec do tipo em `spec/services/helper_types_spec.rb`.

**Sensor calculado com consulta (Lote 4, G8):** a expressão pode usar
`count_points("...")` (e sum/min/max/avg) e o texto `points_where`. Nesse
caso a origem é o local inteiro (`sources` com `"*"`): o helper refaz a cada
mudança de qualquer ponto do local, menos a dele mesmo.
