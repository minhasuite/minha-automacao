# Saúde dos aparelhos

Tela `/saude-aparelhos?site_id=…` (Configurações → Saúde dos aparelhos, botão
na lista de dispositivos, link na Saúde do sistema). Mostra, por local, o que
está com problema nos aparelhos, o **motivo provável** e **reparos seguros**.
Abre igual no app pelo `AppScreen` (`GET /api/v1/screen?path=/saude-aparelhos`):
os reparos viram formulários e links, sem tela própria no app.

Quem vê e repara: técnico ou dono do local (é diagnóstico de cadastro). Cada
reparo ainda pede o papel dele (`Fix#role`). IP, URL e MAC no texto ficam
ocultos para quem não cadastra (`Sensitive.scrub`).

**Nada aqui comanda aparelho.** Reparar é ler de novo (reconectar), varrer a
conta, mudar cadastro (IP, área), apagar cadastro órfão ou levar a outra tela
(substituir, editar, reconfigurar, parear).

## Peças

| Peça | Onde |
|---|---|
| Registro de regras | `Diagnostics::RULES` (`app/services/diagnostics.rb`), classes em `app/services/diagnostics/rules.rb` |
| Registro de reparos | `Diagnostics::FIXES`, classes em `app/services/diagnostics/fixes.rb` |
| O que as regras olham | `Diagnostics::Context` (aparelhos, pontos, hub de cada filho, inventário da conta, duplicados, pulos de leitura numa consulta só) |
| Limiares | `config/device_diagnostics.yml`; o local muda por cima em `sites.settings["device_health"]["values"]` (formulário "Ajustes deste local") |
| Silenciar | `sites.settings["device_health"]["snoozed"]` = `{ref → até}`; AuditEvent `device_health.snooze` |
| Saúde do sistema | verificação `device_health` em `Health::CHECKS` (`Health::Checks::DeviceHealth`, uma linha por local com a contagem; só informa, `alerts: false`) |
| Aviso de bateria | `Diagnostics.notify!` no `HealthCheckJob` (a cada 10 min; uma notificação por achado por semana, `dedup_key`), ligado por local (`battery_notify`) |
| Tela | `Web::DeviceHealthController`, `web/device_health/show` + `_finding` |

Achado (`Diagnostics::Finding`): regra, sujeito (aparelho, ponto ou
integração), aparelho, severidade (`info`/`warn`/`error`), motivo, detalhe,
reparos, desde quando, silenciado até. `ref` = `"<regra>:<id do sujeito>"`.
Informação (`info`, ex.: sem área) aparece na tela mas não conta na Saúde.

## Regras que vêm com o produto

| Chave | Sujeito | Quando | Reparos |
|---|---|---|---|
| `integration_down` | integração | status `error` e ≥ `integration_min_devices` aparelhos dela sem sinal (coordenador Zigbee, conta vencida); os filhos não repetem | reconfigurar, varrer |
| `hub_down` | aparelho | sem sinal e com ≥ `hub_min_children` filhos (`address.via` = `external_id` do hub) sem sinal; os filhos não repetem | reconectar, varrer, substituir |
| `offline` | aparelho | `status` offline/erro há ≥ `offline_hours`; erro depois de `offline_error_days` ("queimado"). Com IP: motivo fala de DHCP | usar IP novo, reconectar, varrer, parear, editar, substituir, apagar |
| `ip_changed` | aparelho | o inventário da conta (`integration.found`) traz outro `address.host` para o mesmo `external_id` | usar IP novo, reconectar, varrer |
| `removed` | aparelho | `removed_at` (sumiu da conta da nuvem) | substituir, varrer, apagar |
| `no_points` | aparelho | nenhum ponto, cadastrado há ≥ `no_points_grace_hours` | varrer, editar, apagar |
| `duplicate` | aparelho | mesmo driver + `external_id`, ou mesmo driver + campos de `duplicate_address_keys` (host, porta, canal, caminho…: câmeras do mesmo DVR não contam); o achado fica no mais novo | substituir, apagar |
| `camera_no_stream` | aparelho | driver `go2rtc` sem ponto `stream` ou com stream sem fonte (`Drivers::Go2rtc.source` nil: sem IP, caminho ou senha) | editar, reconfigurar, substituir |
| `no_area` | aparelho | sem área e nenhum ponto com área (`info`) | definir área |
| `battery_low` | ponto | `device_class: battery` (ou `devices.battery_point_id`) ≤ `battery_low_pct`; erro ≤ `battery_critical_pct`; avisa (`notify: true`) | — |
| `zero_reading` | ponto | medida ≤ 0 há ≥ `zero_hours` da classe (umidade do solo 0% = fora da terra) | reconectar |
| `value_stuck` | ponto | medida igual há ≥ `stuck_hours` da classe com o aparelho online | reconectar |
| `value_jump` | ponto | duas leituras seguidas (`readings`, últimas `jump_lookback_hours`) com diferença ≥ `jump` em ≤ `jump_minutes` | reconectar |

Reparo só aparece quando serve (`Fix.available?`): "Usar o IP novo" só com IP
diferente na conta, "Reconectar" só em driver com leitura (`Polling`),
"Varrer" só com integração, "Substituir" só com outro aparelho no local etc.

## Reparos

| Chave | Tipo | O que faz |
|---|---|---|
| `apply_ip` | ação | grava o IP do inventário no `address.host`; AuditEvent `device.ip_update` (de/para) |
| `reconnect` | ação (comando sensível) | `PollDeviceJob(reconnect: true)`: leitura, Tuya tenta as versões do protocolo |
| `scan` | ação | `Integrations.start_sync!` (traz IP, chave, pontos e marca removidos) |
| `reconfigure` | link | assistente da integração (`connect_integration_path`) |
| `pair` | link | tela de pareamento Zigbee (ver abaixo) |
| `replace` | link | "Substituir aparelho" (`Devices::Replace`) |
| `set_area` | formulário | escolhe a área (auditado pelo `Device`) |
| `edit` | link | edição do aparelho (IP, RTSP, versão) |
| `delete_device` | ação com confirmação (perigo) | AuditEvent `device.orphan_delete` com nome, driver, `external_id`, integração, área e chaves dos pontos; depois apaga |

Na tela, o reparo é refeito na hora: o controller roda o diagnóstico de novo e
só executa se o achado ainda existe e ainda oferece aquele reparo.

## Estender

- **Regra nova**: classe `< Diagnostics::Rule` com
  `describe key:, label:, description:, subject: :device|:point|:integration, severity:, icon:` [`notify: true`],
  `texts` com en/es (o `i18n_coverage_spec` confere), `applies?(sujeito, ctx)`
  e, se precisar, `finding` (chame `super(..., severity:, reason:, detail:, since:)`)
  e `fixes` (chaves de `FIXES`). Nome em `Diagnostics::RULES`. Limiar novo vai
  no YAML; se o local puder mudar, em `settings` + `editable` (o formulário sai do YAML)
  e o texto do campo em `device_health.settings.<chave>` nos três `web.*.yml`.
- **Reparo novo**: classe `< Diagnostics::Fix` com `describe key:, label:, icon:, kind:, role:, confirm:, danger:`,
  `available?(finding, ctx)` e `call(finding, user:, params:)` (ação/formulário)
  ou `url(finding)` (link). Nome em `Diagnostics::FIXES`. Nunca comande aparelho.
- **Classe de sensor nova** para leitura suspeita: linha em `sensors:` do YAML.

## Pareamento Zigbee (TODO de integração)

O fluxo de pareamento é do branch `zigbee-assistente`. O reparo `pair` lê a
rota nomeada em `pair_route` (`config/device_diagnostics.yml`, hoje vazio) e
chama `<pair_route>_path(site_id:, device_id:)`; só aparece para drivers de
`pair_drivers` (`mqtt`). Ao juntar os branches, ponha o nome da rota criada lá
(ex.: `pair_route: zigbee_pairing`) e confira que ela aceita esses parâmetros.

## Testes

`spec/services/diagnostics_spec.rb` (cada regra, limiares do local, silenciar,
reparos, Saúde e aviso de bateria) e `spec/requests/device_health_spec.rb`
(tela, filtros, reparar/silenciar/ajustes, papel por local e o AppScreen).
