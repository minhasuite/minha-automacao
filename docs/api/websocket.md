# API WebSocket

O mesmo `/cable` da web e do app (ActionCable). Serve para painéis de
terceiros, scripts e integrações que querem estado em tempo real e mandar
comandos sem ficar consultando a API REST. É o equivalente da WebSocket API
do Home Assistant, com os mesmos nomes de comando quando existe um igual.

## Conectar

- Web: o cookie da sessão já vale.
- Fora do navegador: `wss://<servidor>/cable?access_token=<access token>`
  (o mesmo Bearer de `POST /api/v1/auth/login`; vence em 30 min, reconecte
  com o novo do `POST /api/v1/auth/refresh`).

Depois de conectar, assine o canal `ApiChannel`:

```json
{"command": "subscribe", "identifier": "{\"channel\":\"ApiChannel\"}"}
```

## Mandar um comando

Cada comando vai como uma mensagem do canal com `action: "command"`, um
`id` seu (número que não se repete na conexão) e o `type`:

```json
{"command": "message", "identifier": "{\"channel\":\"ApiChannel\"}",
 "data": "{\"action\":\"command\",\"id\":1,\"type\":\"get_states\",\"site_id\":\"<local>\"}"}
```

A resposta chega com o mesmo `id`:

```json
{"id": 1, "type": "result", "success": true, "result": [ ... ]}
{"id": 2, "type": "result", "success": false, "error": {"code": "not_found", "message": "site not found"}}
```

## Comandos

| type | campos | resultado |
|---|---|---|
| `ping` | — | `"pong"` |
| `get_config` | — | pessoa, locais (id, nome, papel, fuso), versão e comandos aceitos |
| `get_states` | `site_id` | pontos do local: `id`, `key`, `name`, `device`, `capability`, `value`, `text`, `quality`, `attrs`, `unit`, `changed_at`, `reported_at` |
| `get_commands` | `site_id` | `{ponto: [comandos]}` dos pontos que aceitam comando |
| `call_command` | `point_id`, `command`, `value?` | `{command_id, status, error}`; respeita o papel e o risco do ponto e a sombra do local |
| `subscribe_events` | `site_id`, `event_type?` | `null`; depois chegam eventos com o `id` deste comando |
| `unsubscribe_events` | `subscription` (o `id` do subscribe) | `null` |
| `fire_event` | `site_id`, `event_type`, `event_data?` | `{event_type}` (técnico ou dono; nomes do sistema não) |
| `render_template` | `site_id`, `template`, `mode?` (`liquid`/`expr`) | o texto renderizado |

## Eventos

`event_type` do `subscribe_events`:

- `state_changed`: um ponto do local mudou de valor ou qualidade.
- o nome de um evento de automação (`automation_finished`, os da ação
  "Disparar evento", `fire_event`...).
- `*` (padrão): todos.

```json
{"id": 3, "type": "event", "event": {"event_type": "state_changed", "site_id": "<local>",
 "time_fired": "2026-11-02T20:15:01.120-03:00", "data": {"id": "<ponto>", "value": true, ...}}}
```

## Comando novo

Classe `< WsApi::Command` com `describe type: "meu_comando"` e
`self.call(ctx, msg)` (`ctx.user`, `ctx.site(id)`, `ctx.tenant { }`) + nome
em `WsApi::COMMANDS`. Erro: `raise WsApi::Error.new(:codigo, "mensagem")`.
