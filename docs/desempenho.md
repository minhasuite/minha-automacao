# Desempenho

Medido no servidor da casa em 10/11/2026 (2 h): web p50 200 ms, p95 1,1 s,
máximo 7,8 s. Os lentos eram o quadro das câmeras de nuvem sem vídeo
(`GET /cameras/:id/quadro`) e a recarga de widget (`GET /paineis/:id/w/:widget_id`),
que relia os ~507 pontos do local a cada quadro. O que mudou:

## Painel

- **Lista de pontos com cache curto** (`Dashboards::Cache.points`): o Resolver lê
  os pontos e aparelhos do local na primeira vez que um widget pede, a partir das
  linhas cruas guardadas na memória do processo. A chave é o carimbo do local
  (`Dashboards::Cache.stamp`, uma consulta de ~0,3 ms): contagem e soma do `xmin`
  (versão da linha no Postgres) de pontos, aparelhos e áreas, mais o último
  comando recente e o último alerta. Qualquer gravação, inclusive `update_column`,
  troca o carimbo: valor velho nunca volta. Cada pedido monta os próprios objetos
  (o Resolver mexe no valor do ponto em `Points::Inflight.as_expected`).
- **Recarga de widget** resolve só aquele widget (`Resolver#widget`) com a lista
  acima; os pontos do `points` do JSON são só os que ele usa.
- **Painel resolvido** (`Resolver.cached`, web Início/painel e
  `GET /api/v1/dashboards/:id`): guardado por painel + versão + papel + idioma +
  minuto (o `visible_if` por hora e o tema da noite mudam no minuto) + carimbo, por
  no máximo 60 s. Rascunho/prévia não usa. O que o widget lê de outras tabelas
  (histórico do gráfico, agenda, diário) fica no máximo 60 s atrasado. Nos testes o
  painel resolvido não fica guardado (`Dashboards::Cache.enabled = true` liga).


## Primeira abertura do painel (11/2026)

Na casa, o `Dashboards::Resolver` do painel "Casa" (11 visões, ~507 pontos) levava ~2,3 s
frio; o cache só ajudava quente. Três mudanças, sem mexer em facts/style/hero/autoplay:

- **Só a visão aberta** (`Resolver.new(..., only_view:)`, `Resolver.cached(..., view:, lazy: true)`):
  a web (Início e `/paineis/:id`) resolve só a visão que abre (`?view=`, a do aparelho,
  `open_if`, `start_view`, a primeira: a mesma escolha do `Dashboards.pick_view`); as outras
  vêm com `lazy: true`, sem widgets (título, ícone, caminho, tema e topo continuam). As abas
  da web já são links, então cada visão se resolve ao abrir. O app pede
  `GET /api/v1/dashboards/:id?lazy=1` e, ao trocar de aba, `?lazy=1&view=<id>`; sem `lazy`
  (app antigo) continua tudo.
- **Pré-aquecimento** (`Dashboards::Prewarm` + `DashboardPrewarmJob`): ponto que muda
  (`Point#report!`) ou painel publicado/padrão trocado chama `Prewarm.touch(site)`; no máximo um
  job por local a cada 5 s resolve a visão que abre do painel padrão de cada pessoa/papel
  (web e app, `Dashboard.default_for`) e guarda no `Rails.cache` (Solid Cache, comum aos
  processos). `Dashboards::Cache.resolved` lê a memória do processo, depois o cache comum,
  e só então resolve. A chave continua com o carimbo do local (qualquer gravação de ponto
  troca): o pré-aquecido vale até a próxima leitura de aparelho; numa casa com medição
  chegando a cada segundo, ele acerta menos, e quem salva é o caminho frio curto.
- **Menos consultas e menos voltas no Resolver**: `Points::Query` calcula "o que existe" uma
  vez por resolução e começa pelos pontos da área quando a consulta tem `area` (cartão de
  área, modelo de card); irmãos do tile (brilho, cor, recursos, robô) por
  `Resolver#device_points`; áreas por `Resolver#area` (sem `find_by` por cartão); última
  execução das automações numa consulta (`Resolver#automation_runs`, antes uma por tile);
  risco da cena pelos pontos já lidos (`Scene.max_risk`); modelo de card uma vez por chave
  (`Resolver#memo`).

Medido no banco de dev (`bin/rails perf:seed_paineis` = "Casa Perf": 10 cômodos, 500 pontos,
20 automações como tiles, 6 cenas, cartão de área e modelo por cômodo, 12 visões;
`bin/rails perf:painel`, frio = sem cache, mediana de 5):

| | antes | depois |
|---|---|---|
| painel inteiro (12 visões) | 311,8 ms, 64 consultas | 81,4 ms, 9 consultas |
| só a visão que abre (Início, a mais pesada) | — (resolvia todas) | 52,4 ms, 9 consultas |
| outra visão sob demanda (troca de aba) | — | 10,6 ms, 5 consultas |
| visão que abre, pré-aquecida (outro processo) | — | 3,7 ms |
| um widget (tempo real) | 24,4 ms, 5 consultas | 8,8 ms, 3 consultas |

O servidor da casa é mais lento que a máquina de dev (a proporção de ~2,3 s para os 312 ms
daqui é de ~7x); pela mesma proporção, a primeira abertura do Início deve ficar perto de
0,4 s e a troca de aba perto de 0,1 s. Conferir no Saúde → Desempenho depois do deploy.

## Tempo real

- **Avisos agrupados** (`Points::Broadcast`): medição (`measure`, `counter`) avisa
  no máximo uma vez a cada 1,5 s por ponto; a primeira mudança sai na hora e as
  seguintes viram um aviso no fim da janela (a tela relê o ponto e pega o último
  valor). Liga/desliga, porta, movimento, mudança de qualidade e o fim de comando
  saem sempre na hora. `address.notify_s` no ponto troca a janela (0 = na hora). A
  janela é por processo (quem lê os aparelhos é o worker).
- **Navegador** (`application.js`): junta avisos em 250 ms mas nunca segura mais
  que 1 s, recarrega cada quadro uma vez e, com a aba escondida, guarda para quando
  ela voltar.
- **Por que não mandar o valor pronto**: o texto e o estado do widget dependem do
  papel de quem vê (cadeado, comandos) e de contas sobre vários pontos (cartão da
  área, contadores); mandar HTML/valor por papel no stream do local multiplicaria
  as escritas no Solid Cable. Ficou o aviso só com o id + recarga do quadro,
  agrupada nas duas pontas.

## Histórico

- **Banda morta padrão** (`config/deadbands.yml`, `Points::Deadband`): medição sem
  `deadband` próprio só grava leitura nova quando muda mais que o valor da unidade
  (W 1, V 0,5, A 0,01, °C 0,1, % 1…; `device_class` sobrepõe). `deadband` do ponto
  manda (0 = grava toda mudança); acumulador (`total`, `total_increasing`) não tem
  banda. O valor do ponto e as telas não mudam.

## Câmeras

- `Drivers::Go2rtc.frame` (web `/cameras/:id/quadro` e API `/points/:id/snapshot`):
  câmera de nuvem (`on_demand`) ou que vem falhando busca o quadro em segundo plano
  (até 2 threads no processo web) e responde na hora com o último quadro guardado
  (até 1 h; `X-Camera-Offline: 1` se ela está fora) ou 503 "offline". As boas da
  rede de casa continuam na hora. `X-Frame-At` = hora do quadro.
- A espera depois de uma falha (`FAIL_HOLD`, 60 s) dobra a cada falha seguida até
  15 min (`MAX_HOLD`); quadro bom zera.
- `?w=` (web pela largura do quadro na tela, app pela largura da tela): o servidor
  redimensiona com o libvips para a menor de 320/480/640/960/1280 que cobre e guarda
  ao lado do original.

## Fila

- `ExecuteCommandJob` na fila `commands` (prioridade -10). Tarefas lentas
  (`SlowJob`: rollup, manutenção do histórico, backup, varredura de integração,
  firmware, gravações, migração do HA, atualização) na `slow`, prioridade 10, e no
  máximo `JOB_SLOW_THREADS` (2) rodando juntas pelo semáforo do Solid Queue
  (`limits_concurrency`, grupo "lentas"). Continua **um processo** de worker com
  `queues: "*"`: dois `workers` no `config/queue.yml` abririam outro processo e os
  ouvintes (Tuya, MQTT…) subiriam duas vezes.

## Saúde → Desempenho

`Perf` soma na memória de cada processo (contagem, soma, pior) o tempo de cada tela
(`process_action.action_controller`) e de cada tipo de widget (`Resolver`) e, no
máximo uma vez por minuto, junta no balde da hora no `Rails.cache` (24 baldes). A
verificação `Health::Checks::Performance` mostra as 5 telas e os 5 widgets mais
lentos (média e pior); média acima de 1 s (tela) ou 300 ms (widget) = atenção, sem
aviso.

## Threads e conexões (4 núcleos, 6 GB, com aplicativos ao lado)

| Serviço | Variável | Valor | Por quê |
|---|---|---|---|
| web | `WEB_CONCURRENCY` | 2 | dois processos Puma (~300 MB cada) usam 2 núcleos; o resto fica para worker, Postgres e apps |
| web | `RAILS_MAX_THREADS` | 3 | mais threads disputam o GVL e pioram a latência |
| web | `DB_POOL` (`DB_POOL_WEB`) | 10 | 3 do Puma + 4 do Action Cable + Solid Cable + 2 do quadro em segundo plano; com 3 (o padrão antigo) o tempo real esperava conexão até 5 s |
| worker | `JOB_CONCURRENCY` | 1 | os ouvintes exigem um processo só |
| worker | `JOB_THREADS` | 6 | comandos + tarefas curtas |
| worker | `JOB_SLOW_THREADS` | 2 | tarefas lentas ao mesmo tempo |
| worker | `DB_POOL` | 24 | threads + Solid Queue + ouvintes e leitura periódica |
| db | `shared_buffers` | 256 MB | já no compose |

Total de conexões: 2 × 10 + 24 ≈ 44 (o Postgres aceita 100). As conexões só abrem
quando usadas.

## Números (dev, painel de teste com 500 pontos e 254 widgets)

`script/perf/seed.rb` cria o local "Casa grande" (10 áreas, 100 tomadas virtuais, 500
pontos) e `script/perf/bench.rb` mede (15 pedidos, p50). Máquina de dev (bem mais rápida
que o servidor da casa): olhe a proporção.

| Pedido | Antes | Depois |
|---|---|---|
| Painel inteiro, nada mudou | 120 ms (53 SQL) | 38 ms (38 SQL) |
| Painel inteiro, um ponto mudou | 122 ms | 120 ms |
| Recarga do cartão da área | 18,7 ms (7 SQL) | 10,6 ms (6 SQL) |
| Recarga do cartão da área, um ponto mudou | 20,8 ms | 17,6 ms |
| Recarga de tile | 17,1 ms | 10,5 ms |
| Recarga de contador (selo) | 18,3 ms | 11,1 ms |
| Recarga de lista por consulta | 25,0 ms | 16,6 ms |
| Resolver só do cartão da área | 7,1 ms | 3,4 ms |

Câmera fora do ar (go2rtc num IP que não responde, `script/perf/cam.rb`), cada vez que a
espera da falha vence: antes 3,0 s presos na thread do Puma a cada rodada (e até 15 s
com resposta lenta); depois só a primeira (3,0 s), as seguintes 8–10 ms.
