# Automações (DSL) — referência

F6, ESQUEMA-V1 §5. O simples continua nas primitivas da F4 (pulso, desligar
sozinho, espelhamento, agenda, cena, aviso, alerta). A DSL é para o resto:
várias condições, janela de horário, esperas, ramos, repetição, variáveis e
aviso com texto montado.

Código: `Automations::Dsl` (tipos e validação), `Automations::Engine`
(execução), `Automations::Triggers` (disparo), `Automations::Context`
(valores, expressões e textos), `Automations::Editor` (editor de blocos).

## Formato

```json
{ "triggers": [ ... ], "conditions": [ ... ], "actions": [ ... ] }
```

Precisa de pelo menos um gatilho e uma ação; chave ou campo desconhecido é
erro. **Ponto**: UUID ou a `key` do ponto (`"sala.luz"`); ao salvar vira UUID
e o valor em texto vira o tipo do ponto (`"true"` → `true`). **Duração**:
`"30s"`, `"5m"`, `"1h30m"` ou segundos; até 7 dias; `-` só no deslocamento do
sol. **Dias**: 0 = domingo … 6 = sábado (sem `days` = todos).

### Gatilhos

| type | campos | dispara quando |
|---|---|---|
| `state` | `point`, `from?`, `to?`, `for?` | o valor muda (de/para); com `for`, se ficou assim o tempo todo |
| `numeric` | `point`, `above?`, `below?`, `for?` | o valor **entra** na faixa (não repete enquanto continua nela) |
| `time` | `at` (HH:MM) **ou** `every` (minutos inteiros, 1 min a 24 h), `days?` | no minuto; `every: "10m"` = :00, :10, :20… |
| `sun` | `event` (`sunrise`/`sunset`), `offset?`, `days?` | nascer/pôr do sol do local (precisa de latitude/longitude) |
| `alert` | `rule` (AlertRule), `on` (`open`/`ack`/`resolve`) | o alerta abriu, alguém marcou ciente ou fechou |
| `webhook` | — | `POST /api/v1/hooks/automations/:token` (corpo em `trigger.data`) |
| `manual` | — | só pelo "Executar agora" (que sempre existe) |

Valor que volta junto com a conexão (o ponto estava indisponível) não
dispara, como nas primitivas.

### Condições

| type | campos | vale quando |
|---|---|---|
| `state` | `point`, `is?`, `quality?` (`unavailable`/`error`/`stale`/`good`), `for?` | o ponto está no valor/situação (há pelo menos `for`) |
| `numeric` | `point`, `above?`, `below?` | o valor está na faixa |
| `time` | `after?`, `before?`, `days?` | na janela (pode virar a meia-noite: 18:00 → 05:00) |
| `sun` | `after?`, `before?` (`sunrise`/`sunset`), `after_offset?`, `before_offset?` | depois/antes do sol (depois do pôr e antes do nascer = noite) |
| `expr` | `expr` | a expressão dá verdadeiro (ou número ≠ 0) |
| `and` / `or` / `not` | `conditions` | todas / alguma / nenhuma |

Na lista de condições da automação, todas precisam valer. O trace guarda cada
uma com o valor visto (`agora: Desligado`).

### Ações

| type | campos | faz |
|---|---|---|
| `command` | `point`, `command`, `value?` | comando pelo `Points::Command` (papel x risco, fila, rastreio); a execução vai em `commands.automation_run_id` |
| `scene` | `scene` | aciona a cena |
| `notify` | `title`, `message?`, `channels?` (`in_app`, `push`, `alexa:<id do ponto speaker>`; padrão in_app e push) | `Notifier.deliver!` para dono e administradores, texto Liquid |
| `wait` | `for` **ou** `expr` (segundos) | espera (job agendado; sobrevive a reinício) |
| `wait_for` | `conditions`, `timeout`, `continue_on_timeout?` (padrão `true`) | espera as condições valerem; a mudança de ponto retoma na hora |
| `if` | `conditions`, `then`, `else?` | ramo |
| `choose` | `options: [{conditions, actions}]`, `default?` | a primeira opção que vale |
| `repeat` | `count` **ou** `while` **ou** `until`, `actions` | repete (até 100 voltas); `repeat_index` = volta atual |
| `set` | `var`, `expr` **ou** `value` (Liquid) | define variável |
| `condition` | `conditions` | para aqui (situação "Parada") se não valer |
| `stop` | `reason?`, `error?` | para (com `error`, "Falhou") |

Erro numa ação (comando recusado, expressão inválida) para a execução como
"Falhou" e aparece na lista de automações.

### Helpers (F8e)

Helper é ponto (`docs/helpers.md`), então entra nos blocos de sempre:

- gatilho `state` no helper: mudou de valor (botão: sem `from`/`to`, dispara
  a cada aperto; temporizador terminou: `"to": "finished"`);
- condição `state`/`numeric`/`expr`, como qualquer ponto;
- ação `command` com os comandos do plugin: `set`/`select` (número, texto,
  data e hora, lista), `increment`/`decrement`/`reset` (contador),
  `start` (`value` opcional, ex. `"5m"`)/`pause`/`cancel`/`finish`
  (temporizador), `on`/`off`/`toggle` (liga/desliga e grupo). O editor
  mostra só os que o helper aceita, com os rótulos dele.

```json
{ "triggers": [ { "type": "state", "point": "helpers.rega", "to": "finished" } ],
  "actions": [ { "type": "command", "point": "helpers.visitas", "command": "increment" } ] }
```

## Expressões (dentaku) e textos (Liquid)

Expressão: aritmética, comparação, `and`/`or`/`not`, `if(c, a, b)`, `round`,
`min`, `max`… sem código arbitrário. Variáveis: pontos pela `key`
(`sala.temperatura > 28`), variáveis do `set`, `hour`, `minute`, `weekday`
(0 = domingo), `day`, `month`, `trigger_value`, `repeat_index`. Ponto sem
valor ou nome desconhecido = erro (condição falsa com o motivo no trace).

Texto: `{{ trigger.title }}`, `{{ trigger.point }}`, `{{ trigger.value }}`,
`{{ trigger.data.campo }}` (webhook), `{{ points["sala.luz"].text }}`
(também `.value`, `.quality`, `.changed_at`, `.since_min`),
`{{ site.name }}`, `{{ now | date: "%H:%M" }}` e as variáveis pelo nome.
Até 1000 caracteres.

## Execução

- **Publicar**: o editor mexe no rascunho (`draft`, pode ficar incompleto); a
  publicação valida tudo e vira `automation_versions` (voltar versão publica a
  antiga como a próxima). Nasce desligada; só liga depois de publicada. A
  execução que está esperando termina na versão em que começou.
- **Modos** (o que fazer se disparar com outra em andamento): `single` ignora,
  `restart` cancela a anterior, `queued` enfileira até `max_runs`, `parallel`
  roda junto até `max_runs`. Execução "rodando" sem atualizar há 2 min (o
  processo caiu) não segura o modo.
- **Laço**: mudança causada pela própria automação (pela thread, em pontos
  virtuais em cadeia, ou por comando dela no ponto nos últimos 10 s) vira
  execução "Laço evitado", sem rodar. Corrente com mais de 3 automações idem.
  Mais de 30 execuções por minuto: ignora e mostra o erro na lista.
- **Espera**: o programa (ações achatadas com saltos) para no contador de
  programa; o estado vai para `automation_runs.state` e o
  `AutomationResumeJob` retoma no Solid Queue. `wait_for` olha de novo na
  mudança de ponto, no fim do `for` e a cada minuto (horário, sol).
- **Executar agora**: roda a versão publicada sem as condições (como no HA).
  Exige o papel do ponto de maior risco comandado; ponto crítico pede
  confirmação (`confirm_critical`).
- **Simulação**: roda o rascunho (ou a publicada) a seco com valores
  hipotéticos (`points: {key: valor}`; valor hipotético conta como estável) e
  hora (`at`). Comando não sai (o valor hipotético muda), aviso não é enviado,
  espera não espera e `wait_for` que não vale segue pelo tempo limite. Fica
  gravada (`dry_run`) com o trace.
- **Retenção**: 30 dias e no máximo 200 execuções por automação
  (`ReadingsMaintenanceJob`).
- Editar, publicar, simular e excluir: técnico ou dono. Ver lista e
  execuções: qualquer papel no local.

## Exemplos reais (automações do HA da casa)

Fixtures em `spec/fixtures/automations/` (testadas em
`spec/services/automations_engine_spec.rb`).

**Sala: movimento à noite acende o pendente** (`single`). O "cooldown de 60 s
depois de mexer na luz" do HA vira o `for` em cada luz; o
`wait_for_trigger` vira `wait_for` com `for`:

```json
{ "triggers": [{ "type": "state", "point": "sala.camera_movimento", "from": false, "to": true }],
  "conditions": [
    { "type": "time", "after": "18:00", "before": "05:00" },
    { "type": "state", "point": "cozinha.iluminacao", "is": false, "for": "60s" },
    { "type": "state", "point": "cozinha.pendentes", "is": false, "for": "60s" } ],
  "actions": [
    { "type": "command", "point": "cozinha.pendentes", "command": "on" },
    { "type": "wait_for", "conditions": [{ "type": "state", "point": "sala.camera_movimento", "is": false, "for": "2m" }], "timeout": "6h" },
    { "type": "condition", "conditions": [{ "type": "state", "point": "cozinha.pendentes", "is": true }] },
    { "type": "command", "point": "cozinha.pendentes", "command": "off" } ] }
```

**Portão aberto: alerta em 5, 10, 20… 160 min e depois a cada 160 min**
(`restart`: reabrir recomeça):

```json
{ "triggers": [{ "type": "state", "point": "garagem.sensor_portao", "from": false, "to": true }],
  "actions": [
    { "type": "repeat", "count": 6, "actions": [
      { "type": "wait", "expr": "if(repeat_index = 1, 5, 5 * 2^(repeat_index - 2)) * 60" },
      { "type": "condition", "conditions": [{ "type": "state", "point": "garagem.sensor_portao", "is": true }] },
      { "type": "set", "var": "minutos", "expr": "5 * 2^(repeat_index - 1)" },
      { "type": "notify", "title": "ALERTA", "message": "Portão aberto há {{ minutos }} minutos." } ] },
    { "type": "repeat", "while": [{ "type": "state", "point": "garagem.sensor_portao", "is": true }], "actions": [
      { "type": "wait", "for": "160m" },
      { "type": "condition", "conditions": [{ "type": "state", "point": "garagem.sensor_portao", "is": true }] },
      { "type": "notify", "title": "ALERTA", "message": "Portão aberto há {{ points[\"garagem.sensor_portao\"].since_min }} minutos." } ] } ] }
```

**Bateria baixa do celular** (limite + a cada 10 min, expressão):
`triggers: [{numeric, below: 15}, {time, every: "10m"}]`, condições
`numeric below 15`, `state alerta_reconhecido is false` e
`expr "eva.carregando = false"`.

**Hub Zigbee offline**: `{time, every: "30m"}` + `{state, point:
"cozinha.hub_zigbee", quality: "unavailable"}` + `notify`.

**Webhook para a IA avisar** (`queued`): `set mensagem = {{ trigger.data.mensagem | strip }}`,
`condition expr "mensagem != ''"` e `if canal = 'celular' or canal = 'ambos'`
→ `notify`. O anúncio na Alexa é o canal `alexa:<id do ponto da Echo>` (F8).

**Cena da cozinha aciona o portão** (ESQUEMA-V1 §5): `state
cozinha.switch_cena to true` → `command garagem.portao_eletronico pulse` +
`command cozinha.switch_cena off` (o pulso de 3 s é o `pulse_ms` do ponto).

## API

`/api/v1/sites/:id/automations` (GET, POST), `/api/v1/automations/:id` (GET,
PATCH, DELETE), `POST …/publish`, `POST …/revert {version}`, `GET
…/versions`, `POST …/simulate {points, at, trigger, definition?, published?,
skip_conditions?}`, `POST …/run` (202), `GET …/runs` (paginado,
`?dry_run=`), `POST …/webhook` (gera o token, mostrado só nessa resposta),
`GET /api/v1/automation_runs/:id` (trace) e `POST
/api/v1/hooks/automations/:token` (sem login, até 10 KB, 60/min). Em
`openapi.yaml`.
