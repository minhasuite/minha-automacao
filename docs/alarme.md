# Painel de alarme (Pacote 3)

Genérico, como o Alarmo/`manual` do HA: um helper **Painel de alarme**
(`HelperTypes::AlarmPanel`). Não toca nada sozinho: sirene, aviso e luzes
são automações do usuário.

## Estados

`disarmed` → (`arm_<modo>`) → `arming` (atraso de saída) → `armed_<modo>` →
(sensor do modo dispara) → `pending` (atraso de entrada) → `triggered` (pelo
"tempo disparado") → volta ao modo armado. `disarm` (com código) volta a
`disarmed` de qualquer estado; `trigger` = pânico.

Modos em `AlarmPanel::MODES` (em casa, ausente, noite, férias). Cada modo
ligado tem os seus sensores (abertura, movimento, liga/desliga, portão),
atraso de saída e de entrada. Sensor ativo = valor verdadeiro ou `open`, com
sinal bom. Armar com sensor do modo aberto é recusado (diz quais).

## Código

- 4 a 8 números, guardado só como bcrypt (`address.code_digest`). A API
  mostra `has_code`, nunca o hash.
- O comando confere o código e o tira do argumento antes de gravar
  (`Points::Command#value=`): a tabela de comandos nunca tem o código.
- "Pedir o código também para armar" é opcional.
- Valor direto (`POST /points/:id/value`, ferramentas) é recusado.
- Risco padrão do painel: sensível (operador para cima).

## Tempos

Atrasos e tempo disparado são `HelperTimerJob` com carimbo (`address.stamp`),
como o temporizador: sobrevivem a reinício e job velho não age. O job chama
`plugin.finish_due!` de qualquer helper (o temporizador também).

## Automações

- Gatilho **Alarme mudou** (`alarm`): `point`, `to` (estado), `from?`.
- Condição **Alarme está** (`alarm`): `point`, `is` (estado ou `armed` = qualquer modo armado).
- Ex.: "Alarme mudou para Disparado → Avisar no celular e ligar a sirene".
  Nunca teste com sirene real.

## Painel

Widget **Painel de alarme** (`alarm`, `bind` = o painel): estado, contagem,
quem disparou, teclado (web: Stimulus `keypad`; app: o mesmo desenho) e os
botões dos modos ligados (vindos do registro). O comando vai pelo
`PointsController#command` (papel x risco).

## Estender

Modo novo = linha em `MODES` (`label`, `command`); aparece no formulário, no
widget, nos comandos, no gatilho e na condição. Prova com `stub_const` em
`spec/services/pacote3_presence_alarm_spec.rb`.
