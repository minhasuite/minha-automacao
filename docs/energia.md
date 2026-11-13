# Energia por aparelho (11/2026)

Tela **Energia** (`/energia`, menu lateral; no app em Mais → Energia, pela
mesma tela do servidor), o card **"Gasto do mês por aparelho"** e o **aviso de
consumo fora do normal**. Não há tabela nova: tudo sai dos rollups de hora
(`reading_rollups`, `RollupReadingsJob` às :05) pelo mesmo cálculo do widget
`energy` (`Dashboards::Energy`): ponto acumulado em kWh/Wh (o `add_ele` das
tomadas Tuya) = diferença entre horas; ponto de potência (W, o `cur_power`) =
média da hora × 1 h. Serviço: `EnergyUse` (`app/services/energy_use.rb`).

## Tela

- Período: Hoje, Semana (seg a dom) ou Mês, no fuso do local.
- Consumo e custo totais, e o **mesmo trecho do período anterior** (mês
  passado até o mesmo tempo decorrido) com a variação em %.
- **Ranking por aparelho** (`Ss::RankListComponent`): pelo custo quando há
  tarifa, senão pelo kWh. Por aparelho vale o ponto de energia (kWh) e, sem
  ele, o de potência; helpers ficam fora (não contar duas vezes um medidor
  por ciclo).
- **Comparação** por aparelho com o trecho anterior.
- Ver: qualquer papel do local. Mudar tarifa e regra: técnico+ (AuditEvent
  `energy.settings`).

## Tarifa do local

`sites.settings["energy"]`:

| Chave | O quê |
| --- | --- |
| `tariff_point` | helper Tarifa (tarifa branca: custo hora a hora pelo `price_at`) ou Número em R$/kWh |
| `tariff` | tarifa fixa, sem ponto |

Sem nenhum dos dois vale o primeiro helper Tarifa do local. O widget
`energy_breakdown` sem `tariff`/`tariff_point` próprios usa a tarifa do local.

## Aviso de consumo fora do normal

Regra de dado em `sites.settings["energy"]["watch"]` (padrões em `EnergyUse::WATCH`):

| Chave | Padrão | O quê |
| --- | --- | --- |
| `enabled` | falso | liga o aviso |
| `factor` | 2,0 | quantas vezes a média da hora (1,1 a 20) |
| `min_kwh` | 0,1 | excesso mínimo sobre a média, em kWh (barra ruído) |
| `days` | 28 | janela de aprendizado (7 a 90 dias) |
| `min_days` | 7 | dias de dado antes de avisar |
| `ignore` | [] | aparelhos que não avisam |

**Limiar aprendido:** a média do aparelho **naquela hora do dia** nos dias
anteriores da janela (`EnergyUse.baseline`). Hora sem rollup num dia que já
tinha dado conta **zero**: o motor da piscina parado de madrugada tem média
0, e ligado às 3h passa do excesso mínimo e avisa. Fora do normal =
`kWh > factor × média` **e** `kWh − média ≥ min_kwh`.

`EnergyWatchJob` (recorrente, toda hora às :15, depois dos rollups) olha a hora
que fechou em cada local com o aviso ligado e manda **um** aviso pelo
`Notifier.notify!` (`kind: "alerta"`, para dono e administradores) com todos
os aparelhos fora do normal juntos: `data.tag = "energia:<local>"` (o novo
substitui o anterior, agrupado), `data.group = "energia"`, `data.url` = a tela,
`dedup_key` por local e hora (uma vez por hora). Na sombra o `Notifier` segura.
A tela mostra a mesma conta da última hora num quadro de atenção.

## Card "Gasto do mês por aparelho"

É o widget `energy_breakdown` com `period: "month"` e `metric: "cost"`
(ordena e mostra pelo custo; o kWh fica na legenda). Entra pelo "Adicionar ao
painel" da tela Energia (`Dashboards::AddTo::SOURCES["energy_month"]`) ou pelo
editor (campo "Mostrar"). O app desenha o mesmo widget (`metric` no dado).

## Estender

- Outro tipo de regra de aviso = outra chave em `watch` lida pelo
  `EnergyUse.anomalies` (é dado, não código por aparelho).
- Medidor novo (Shelly, Tasmota, Z2M…) entra sozinho: qualquer ponto
  numérico em kWh/Wh ou W/kW (ou `device_class` energy/power).

## Spec

`spec/requests/presenca_energia_spec.rb` (rollups falsos; nada de aparelho real).
