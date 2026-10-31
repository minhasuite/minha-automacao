# Pessoas, zonas e presença (Pacote 3)

Como o `person` e o `zone` do Home Assistant, sem nada fixo da casa: tudo é
helper (ponto), rastreador por registro e gatilho/condição por plugin.

## Peças

| Peça | Onde | O que é |
| --- | --- | --- |
| Zona | Helpers → Zona (`HelperTypes::Zone`) | Círculo (centro e raio). "É a casa" usa a latitude/longitude do cadastro do local. Valor = quantas pessoas estão nela. |
| Pessoa | Helpers → Pessoa (`HelperTypes::Person`) | Ligada (ou não) a um usuário, com até 10 fontes em ordem de prioridade. Valor = nome da zona ou "Fora". |
| Rastreador | `People::TRACKERS` | Lê uma fonte e diz a zona: `Gps` (atributos `latitude`/`longitude` ou `zone`), `WifiSsid` (`device_class: wifi_ssid`; rede da lista "Wi-Fi de casa" = casa), `Connected` (`device_class: presence/connectivity`; ligado = casa, desligado = fora). |
| Rastreador de rede | Integrações → Rastreador de rede (`NetworkTrackerPlugin`) | Um aparelho por endereço com o ponto "Conectado". Sondas em `PROBES` (`ping`, `tcp`; recusa TCP = presente). "Fora" só depois de `consider_home` sem resposta (padrão 3 min). Só leitura. |
| App do celular | `MobileAppPlugin` | O ponto "Presença" ganha `device_class: location` e o atributo `zone`; o Wi-Fi, `device_class: wifi_ssid`. |

A zona da casa nasce sozinha na primeira pessoa (raio do app do celular ou
150 m).

## Regra da pessoa

Na ordem das fontes, vale a primeira que diz **em qual zona** a pessoa está.
"Fora" só ganha se nenhuma fonte disser uma zona (presença ganha de ausência,
como no HA). Fonte sem sinal (qualidade ruim) não conta; se nenhuma fonte
souber, a pessoa fica sem sinal com o último valor. A pessoa refaz quando o
valor **ou os atributos** de uma fonte mudam (`Point#report_attrs!` chama
`HelperTypes.on_change`).

## Automações

- Gatilho **Pessoa entrou ou saiu de zona** (`zone`): `point` = pessoa, `zone` = zona, `event` enter|leave.
- Gatilho **Presença na zona** (`presence`): `point` = zona, `event` first_arrived (0 → 1) | all_left (1 → 0).
- Condição **Alguém na zona** (`zone`): `point` = zona, `state` someone|nobody.
- O gatilho "Ponto mudou" também serve (a pessoa é um ponto enum).

## Painel e API

- Widget **Pessoas** (`people`): todas as pessoas (ou só as de `zone`), com a zona e desde quando.
- `GET /api/v1/sites/:id/people`: pessoas e `meta.zones` (contagem). Nunca coordenadas.

## Privacidade

- A coordenada exata fica só no servidor de casa, nos **atributos** do ponto
  "Presença" do celular (sem histórico; a leitura guarda só "Em casa"/"Fora").
- Configurações da integração "App do celular": **Guardar a localização exata
  por (horas)** (padrão 24, até 720). Depois disso sem leitura nova, o
  `MobileAppPlugin.tick` (a cada minuto) apaga latitude, longitude e precisão;
  ficam a distância de casa e a zona. `0` = nunca grava a coordenada.
- Pessoa e zona guardam só o nome da zona e o nome da fonte que decidiu.
- A API de pontos não mostra atributos; o app do celular manda a localização
  só com a permissão da pessoa (Mais → Sensores do celular).

## Estender

- Rastreador novo: classe em `People::Trackers` (`describe label:`, `applies?(ponto)`,
  `zone(ponto, pessoa, zonas)`) + nome em `TRACKERS`. Spec com `stub_const` em
  `spec/services/pacote3_presence_alarm_spec.rb`.
- Sonda de rede nova: módulo com `label` e `up?(host, settings)` + linha em
  `NetworkTrackerPlugin::PROBES`.
