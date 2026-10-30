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
100 itens por vez. Templates do HA (Jinja) não convertem: aparecem como
"condição template" e devem ser refeitos com `expr`, `count_points` ou
Liquid.

O conversor também leva o controle de fluxo (`if`, `choose`, `condition` como
ação, `stop`, `repeat` com `count`/`while`/`until`, `variables` → `set`) e os
gatilhos `time_pattern` ("/N" minutos ou horas), `webhook` e `event` (gatilho
"Evento"). Condição que não converte dentro de um bloco é anotada ("o bloco
ficou sem ela"). Nas 58 automações reais da casa, 41 viram blueprint (6 sem
perda) e 17 ficam de fora (gatilho de aparelho, início do HA, horário por
entidade).
