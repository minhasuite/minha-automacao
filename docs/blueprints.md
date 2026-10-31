# Blueprints (F8f)

Modelo de automação (ou script) com entradas tipadas. Tela: aba
**Blueprints** da seção "Automações e cenas" (`/locais/:id/blueprints`).

## Formato (`Blueprint`)

```json
{ "name": "Desligar após X minutos ligado", "domain": "automation", "mode": "single",
  "inputs": [
    { "key": "alvo", "label": "O que desligar", "type": "point", "filter": { "capability": ["onoff"], "writable": true } },
    { "key": "tempo", "label": "Depois de ligado por", "type": "duration", "default": "30m" } ],
  "definition": {
    "triggers": [ { "type": "state", "point": { "!input": "alvo" }, "to": true, "for": { "!input": "tempo" } } ],
    "actions": [ { "type": "command", "point": { "!input": "alvo" }, "command": "off" } ] } }
```

- `inputs[].type`: `point` (com `filter` {`capability`: [...], `writable`,
  `area`: nome da área}), `number`, `text`, `boolean`, `select` (`options`),
  `duration` (`"5m"` ou segundos) e `time` (`HH:MM`). Obrigatória quando não
  tem `default` (ou `required: false`).
- `{"!input": "chave"}` vale no lugar de **um valor inteiro** da DSL (não
  dentro de texto). Entrada opcional vazia some da definição.

## Criar a partir do blueprint

`/blueprints/:id/usar` monta o formulário pelas entradas (o ponto vem
filtrado pela capacidade e agrupado por área). `Blueprint#create_automation!`
troca as entradas, cria a automação ligada ao blueprint (`blueprint_id`,
`blueprint_inputs`, `blueprint_version`) e publica se a DSL fechar (nasce
desligada). Comanda ponto crítico: fica no rascunho, porque publicar no
editor pede a confirmação.

**Atualização propaga com aviso**: mudar `inputs`, `definition` ou `mode`
sobe a `version` e refaz o **rascunho** de cada automação ligada (mesmas
entradas). A versão publicada não muda sozinha: a lista mostra "Blueprint
mudou" e o editor, "o blueprint mudou (versão N)... revise e publique" com
"Refazer rascunho". Publicar grava a versão usada.

## Prontos

Um JSON por blueprint em `config/blueprints/` (genéricos, nada da casa):
"Ligar luz por movimento com tempo de desligar", "Avisar quando sensor ficar
aberto por X minutos" e "Desligar após X minutos ligado".
`Blueprints.sync_builtin!` cria/atualiza os do local ao abrir a aba
(`source: "builtin:<arquivo>"`); mudar o arquivo propaga como acima. Pronto
não se edita nem se exclui.

## Importar do Home Assistant

`Blueprints::HaImport`: YAML colado ou URL (GitHub `blob` → raw, gist →
`/raw`, tópico da comunidade → primeiro bloco com `blueprint:`; só https e
só esses hosts, até 200 KB, 10 s). `!input x` vira `{"!input": "x"}` antes do
`YAML.safe_load`.

| do HA | vira |
|---|---|
| selector `entity`/`target` (domínio/device_class) | `point` com filtro: light/switch/fan/input_boolean → `onoff` (gravável); binary_sensor motion/occupancy/presence → `motion`; door/window/opening/garage_door → `contact`; sensor → `measure` |
| selector `number`, `boolean`, `select`, `text`, `time`, `duration` | o tipo daqui (`duration` {minutes: 5} → `"5m"`) |
| gatilho `state`, `numeric_state`, `time`, `sun` | `state` (`"on"`/`"off"` → true/false), `numeric`, `time`, `sun` |
| condição `state`, `numeric_state`, `time` | `state` (`is`), `numeric`, `time` (weekday → dias) |
| ação `light/switch/fan/input_boolean/homeassistant.turn_on/turn_off/toggle` | `command` on/off/toggle (um por entidade) |
| `notify.*`, `persistent_notification.create` | `notify` (in_app + push / só in_app) |
| `delay` | `wait` |

O resto (outros selectors, entidade fixa, `wait_for_trigger`, `choose`,
`variables`, template...) vai para `unsupported` e aparece na tela como
"não suportado: …"; a automação criada roda sem essas partes. Sem nenhum
gatilho ou nenhuma ação conversível, a importação é recusada com a lista.

### Automações e scripts do HA (Lote 4, G32)

A mesma tela aceita o `automations.yaml` (lista), uma automação só ou o
`scripts.yaml`. Cada automação ou script vira um blueprint deste local
(`Blueprints::HaImport.import`), com o mesmo conversor e o mesmo relatório do
que não converteu. Cada entidade fixa (`entity_id`, inclusive em `target`)
vira uma entrada de ponto com o nome da entidade (`switch.varanda`) e o
filtro de capacidade pelo domínio. Em "Criar automação" a pessoa escolhe o
ponto daqui de cada entidade; a automação nasce como qualquer outra criada
de blueprint (desligada, ponto crítico só no rascunho). Item sem nada que
rode aqui (sem gatilho ou sem ação) fica de fora e é contado no aviso. Até
100 itens por vez. O Jinja comum é traduzido (Lote 5, abaixo); o resto
aparece como "condição template" ou "texto com template" e deve ser refeito
com `expr`, `count_points` ou Liquid.

O conversor também leva o controle de fluxo (`if`, `choose`, `condition` como
ação, `stop`, `repeat` com `count`/`while`/`until`, `variables` → `set`) e os
gatilhos `time_pattern` ("/N" minutos ou horas), `webhook` e `event` (gatilho
"Evento"). Condição que não converte dentro de um bloco é anotada ("o bloco
ficou sem ela").

### Lote 5: o que antes ficava de fora

- **Aparelho**: gatilho, condição e ação `device` (`turned_on`, `no_motion`,
  `is_off`, `turn_on`...) e `device_id` no alvo viram estado ou comando numa
  entrada "Aparelho do HA xxxxxxxx (domínio)". Tipo com `no_`/`not_` ou
  `off` = desligado; `changed_states` = qualquer mudança.
- **Início do HA** (`homeassistant: start`) vira o gatilho "Evento" com
  `system_started` (o servidor subiu).
- **Horário**: vários horários viram um gatilho cada; segundos (`32400`)
  viram `09:00`; `weekday` vira `days`; horário vindo de entidade
  (`at: input_datetime.x`) vira "no horário do ponto" (`at_point`).
- **Agenda**, **cena** (entrada do tipo cena, escolhida entre as do local),
  **script** (`script.x` ou `script.turn_on`: comando `run` no ponto do
  script, com os campos constantes), **helpers** (`set_value`,
  `select_option`, `start`, `increment`...), `event`, `wait_for_trigger` de
  evento, `wait_template`, `calendar.get_events` com `duration`,
  `weather.get_forecasts`, `ai_task.generate_data` e `repeat.for_each`.
- **Espelho** `switch.turn_{{ trigger.to_state.state }}` vira "se o gatilho
  ligou, liga; senão, desliga".
- **`id` do gatilho** vai junto; a condição `trigger` vira `trigger.id = 'x'`.
- **Jinja** (`Blueprints::Jinja`): `states()`, `is_state()`, `now()` (hora,
  minuto, dia, mês, dia da semana, `strftime`, `isoformat`),
  `as_timestamp(now())`, `iif()`, `a if c else b`, `in [...]`, comparações,
  aritmética, `and`/`or`/`not` e os filtros `int`, `float`, `round`, `bool`,
  `trim`, `count`, `default`, `join`. Condição vira `expr`; texto vira
  Liquid (o que não tem filtro Liquid é calculado com `{{ "expr" | calc }}`).
  A entidade citada no texto vira entrada e aparece como `[[entrada]]`, que o
  "Criar automação" troca pela `key` do ponto escolhido.

### Lote 7: o Jinja que ainda segurava rascunho

| do HA | vira |
|---|---|
| `{% set x = ... %}`, `{% if %}/{% elif %}/{% else %}`, `{% for x in lista [if cond] %}`, `for k, v in d.items()` | `{% assign x = 'expr' \| calc %}` (ou `capture` se for texto), `if` (variável sozinha usa o vazio do Liquid; o resto vai pela conta), `for` |
| `namespace(n=0, l=[])`, `ns.n = ...`, `ns.l = ns.l + [item]` | variáveis `ns_n`/`ns_l`; o item entra por `capture` + `concat` |
| `states.ponto.x.last_changed` / `.last_updated`, `now()`, `(a - b).total_seconds()`, `timedelta(minutes=2)`, `as_timestamp(...)`, `as_local(...)` | segundos: `ponto.changed_at`, `timestamp`, a diferença; texto ISO por `to_timestamp(x)` |
| `state_attr('x', 'a')`, `states.x.y.attributes.a`, `is_state_attr` | `ponto.attrs.a` (expressão) / `points["ponto"].attrs.a` (texto) |
| `x is (not) defined`, `x is (not) none`, `x \| default(v)` | `defined('x')` (e `if(defined('x'), x, v)`) |
| `{'a': 'A'}.get(x, 'padrão')`, `{'a': 1}[x]` | `if(x = 'a', 'A', 'padrão')` |
| `.split('_')`, `[n]`, `[-1]`, `[:n]` (texto) | `\| split: "_"`, `\| slice: n \| first`, `\| last`, `\| slice: 0, n` |
| `label_entities`, `area_entities` (+ soma), `integration_entities`, `states`, `states.dominio`, com `select('is_state', 'on')`, `select('in', ...)`, `reject('is_state', 'unavailable')`, `selectattr('state', 'eq', ...)` e `\| list \| count` | `count_points('tag=... area=... state=on')` (Points::Query) |
| `config_entry_attr(x, 'state')` | `if(integration_ok('tipo'), 'loaded', 'not_loaded')` |
| `trigger.to_state.attributes.event_type` (entidade de evento) | `trigger.value` |
| `delay` com template (`{minutes: '{{ x }}'}`) | "Esperar" com segundos por expressão |
| valor de helper com template (`timer.start` duração `{{ x }}`) | comando com valor em texto Liquid (resolvido na execução) |
| `logbook.log`, `system_log.write` | "Anotar no histórico da execução" (só no trace; roda em sombra) |
| `rest_command.x` (com o `configuration.yaml` na importação da instalação) | "Definir variável" dos campos + "Chamar HTTP" com URL, método, corpo, cabeçalhos e tempo limite |
| `homeassistant.reload_config_entry` (id direto ou numa variável constante), `<dominio>.reload` | "Recarregar integração" daqui (`tuya`, `alexa`, `xiaomi`...) |

Continuam sem tradução (o item fica no rascunho, com a nota): `from_json`,
`map(attribute=...)`, `select('match', ...)`, iterar `states`/`states.x` e
`states[e]`, `area_name`, `expand`, `this`, `.replace()`, `.date()`, o
`stdout` do `shell_command` e `{% macro %}`.

Nas 58 automações reais da casa: antes 41 viravam blueprint (6 sem perda);
agora 57 viram (28 sem perda, todas com a DSL válida). A que sobra só chama
`shell_command`. Nos 14 scripts: de 9 (0 sem perda) para 12 (2 sem perda).
