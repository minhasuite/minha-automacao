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

## Tolerância, confiança e cômodo (11/2026)

- **Tolerância para sair** (`address.away_delay_s`, campo "Tolerância para
  sair (min)", até 60): sair de uma zona para "Fora" só vale depois desse
  tempo sem nenhuma fonte dizer uma zona. No meio a pessoa fica onde estava
  com o atributo `leaving_at`; o relógio dos helpers (`Person.tick`, a cada
  minuto) confirma, e a mudança conta de quando começou a sair. Chegar e
  trocar de zona valem na hora. Pessoa nova nasce com 3 min
  (`People::AWAY_DELAY_S`); a antiga, sem a chave, sai na hora como antes.
- **Confiança** do rastreador (`describe confidence:`): `Gps` e `WifiSsid`
  alta, `Connected` média, `Room` e `Face` baixa. A lista de fontes do
  formulário e a ordem do assistente vêm por ela (`People.by_confidence`:
  celular > rede > cômodo/rosto). A prioridade continua a ordem escolhida.
- **Cômodo**: a primeira fonte `Room` (ESPresense) que sabe o cômodo vira o
  atributo `room` da pessoa (widget, API `people` e a tela).

## Tela Pessoas (`/pessoas`)

Menu lateral (e no app, Mais → Pessoas, pela tela do servidor). Só morador
para cima (como o Mapa). Mostra quem está em casa, fora e sem sinal; por
pessoa a zona, o cômodo, desde quando, a fonte que decidiu, a saída pendente
(tolerância), **o que cada fonte diz agora** com a confiança
(`People.opinions`) e **as chegadas e saídas do dia** pelas leituras da
pessoa (`People.timeline`, só o nome da zona).

**Assistente "Presença pelo celular"** (`People::Setup`): para cada morador
do local, os passos conta → app → localização → pessoa. Conta: o dono gera ali
o convite de morador (link de uso único). App: celular registrado
(`MobileAppPlugin`, aparelho com `address.user_id`). Localização: o ponto
"Presença" do celular já recebeu leitura (a pessoa ligou em Mais → Sensores
do celular e deu a permissão). Pessoa: técnico+ toca "Criar pessoa" e nasce o
helper ligado ao usuário com as fontes do celular pela confiança e a
tolerância padrão (`POST /pessoas`). Nada de coordenada aqui.

Card **"Quem está em casa"**: o widget `people` (agora com o cômodo e um
atalho para a tela), pelo "Adicionar ao painel" da tela
(`Dashboards::AddTo::SOURCES["people"]`).

## Automações

- Gatilho **Pessoa entrou ou saiu de zona** (`zone`): `point` = pessoa, `zone` = zona, `event` enter|leave.
- Gatilho **Presença na zona** (`presence`): `point` = zona, `event` first_arrived (0 → 1) | all_left (1 → 0).
- Condição **Alguém na zona** (`zone`): `point` = zona, `state` someone|nobody ("se ninguém em casa").
- Condição **Pessoa na zona** (`person`): `point` = pessoa, `zone` = zona, `state` in|out ("se a Kadidja estiver em casa").
- "Quando a Kadidja chegar" = gatilho **Pessoa entrou ou saiu de zona** com a zona Casa e `enter`.
- O gatilho "Ponto mudou" também serve (a pessoa é um ponto enum).

## Painel e API

- Widget **Pessoas** (`people`): todas as pessoas (ou só as de `zone`), com a zona e desde quando.
- `GET /api/v1/sites/:id/people`: pessoas e `meta.zones` (contagem). Nunca coordenadas.
- **Mapa** (`/mapa`, widget `map`, `GET /api/v1/sites/:id/map`): zonas em
  círculo, pessoas pela coordenada exata do rastreador (ou no centro da zona
  em que estão, marcado como aproximado) e o **trajeto do dia** (atributo
  `track` do "Presença" do app: um ponto a cada 30 m andados, só de hoje, até
  288). Leaflet 1.9.4 por importmap e tiles do OpenStreetMap, carregados só
  quando há mapa na tela. Só **morador para cima** vê (`Maps::MIN_ROLE`):
  visitante e operador recebem 403 na tela e na API e o widget vem sem
  coordenada; chave de integração não lê.

## Privacidade

- A coordenada exata fica só no servidor de casa, nos **atributos** do ponto
  "Presença" do celular (sem histórico; a leitura guarda só "Em casa"/"Fora").
- Configurações da integração "App do celular": **Guardar a localização exata
  por (horas)** (padrão 24, até 720). Depois disso sem leitura nova, o
  `MobileAppPlugin.tick` (a cada minuto) apaga latitude, longitude e precisão;
  ficam a distância de casa e a zona. `0` = nunca grava a coordenada. O
  trajeto do dia (`track`) só existe com a coordenada exata e some junto.
- Pessoa e zona guardam só o nome da zona e o nome da fonte que decidiu.
- A API de pontos não mostra atributos; o app do celular manda a localização
  só com a permissão da pessoa (Mais → Sensores do celular).

## Rastreadores dos apps (11/2026)

- `Face` (Double Take): ponto com `address.tracker = "face"`; visto há pouco
  (`hold_s`) = em casa; não visto = sem opinião.
- `Room` (ESPresense): ponto com `address.tracker = "room"`; num cômodo = em
  casa; `not_home` = sem opinião. O valor é o cômodo (para automações por
  cômodo) e há o sensor "Ocupado" por cômodo.
- OwnTracks: o ponto "Presença" da integração `owntracks` usa o `Gps` (valor
  = zona; coordenada só nos atributos, apagada depois de `location_keep_h`
  pelo `OwntracksPlugin.tick`, contada da hora da posição).

Ordem: `Gps WifiSsid Face Room Connected`.

## Estender

- Rastreador novo: classe em `People::Trackers` (`describe label:, confidence:`, `applies?(ponto)`,
  `zone(ponto, pessoa, zonas)`) + nome em `TRACKERS`. Spec com `stub_const` em
  `spec/services/pacote3_presence_alarm_spec.rb`.
- Sonda de rede nova: módulo com `label` e `up?(host, settings)` + linha em
  `NetworkTrackerPlugin::PROBES`.
