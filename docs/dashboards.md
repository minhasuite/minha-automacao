# Dashboards (F5)

O dashboard é **dirigido pelo servidor**: um JSON versionado (ESQUEMA-V1 §6) que a
web renderiza com Turbo e o app Flutter (F7) renderiza com widgets nativos. O
servidor valida (`Dashboards::Schema`), resolve para quem está vendo
(`Dashboards::Resolver`) e gera o automático (`Dashboards::Generator`).

## Tabelas

- `dashboards`: `site_id`, `name`, `kind` (`home`/`plant`/`custom`), `auto`,
  `site_default`, `definition` (publicada), `draft` (rascunho do editor),
  `schema_version`, `version`, `roles[]` (vazio = todos; dono sempre vê),
  `position`.
- `dashboard_versions`: uma linha por publicação (`version`, `definition`,
  `author_id`). Voltar versão publica a antiga como a próxima.
- `users.dashboard_prefs`: `{"site": <site_id>, "<site_id>": <dashboard_id>}`
  (o local e o painel que abrem no Início da pessoa).

## Dashboard automático

Local sem dashboard ganha um (`auto: true`, padrão do local). Enquanto for
automático, a definição sai do gerador a cada leitura: área e ponto novos
entram sozinhos. A primeira publicação (editor ou API) o torna manual.

- **Início**: selos "N ligados" e "W agora" (soma da potência); seções Luzes
  (pontos liga/desliga com nome/etiqueta de luz, em âmbar), Agora (lista dos
  ligados + alertas), Consumo (gráfico de potência 24 h + lista), Segurança
  (risco sensível/crítico, portão, abertura e movimento), Câmeras (um widget
  `camera` por câmera), Cenas e Áreas (um cartão por área quando há mais de
  uma). Nas views de área a câmera também vira widget `camera`; o robô vira widget `vacuum`
  (seção "Robô" no Início e, na view da área, só ele na seção do aparelho).
- **Uma view por área** (`area` = id da área): uma seção por dispositivo
  (luzes primeiro) e o gráfico de consumo da área. Tensão e corrente ficam de
  fora; ponto oculto ou desativado também.
- Ids derivados dos ids de pontos e áreas (estáveis entre leituras).

## JSON (`schema_version: 1`)

```json
{
  "schema_version": 1,
  "views": [
    {
      "id": "home", "title": "Início", "icon": "home", "area": null,
      "badges": [ { "id": "b-on", "type": "stat", "label": "ligados",
                    "query": { "capability": "onoff", "state": "on" }, "aggregate": "count" } ],
      "sections": [
        { "id": "s1", "title": "Luzes", "icon": "light-bulb",
          "span": { "mobile": 12, "tablet": 12, "desktop": 6 },
          "widgets": [
            { "id": "w1", "type": "tile", "bind": "<point_id ou key>", "label": "Teto",
              "color": "amber", "tap": "toggle",
              "span": { "mobile": 6, "tablet": 4, "desktop": 3 },
              "visible_if": { "role": ["owner", "resident"] } }
          ] }
      ]
    }
  ]
}
```

Regras: ids únicos no dashboard inteiro (`[A-Za-z0-9_-]`, até 100), até 400
widgets, até 256 KB. `bind` aceita id (preferido: não quebra se a `key` mudar)
ou `key` do ponto.

### Campos comuns do widget

| Campo | Valor |
|---|---|
| `span` | `{mobile, tablet, desktop}`, de 1 a 12 colunas (padrão 12/6/4). Seção também aceita `span` (padrão 12/12/12). Celular < 640 px ≤ tablet < 1024 px ≤ computador |
| `visible_if` | `role` (lista de papéis; quem não está some do JSON), `state` `{point, is}` (`is` valor ou lista), `numeric` `{point, above, below}` (faixa aberta, Lote 4), `quality` (lista, do ponto do widget), `time` `{after, before}` em HH:MM no fuso do local (pode passar da meia-noite), `any` (lista de 1 a 10 condições: basta uma, sem `role`/`screen` dentro), `screen` (lista de `mobile`/`tablet`/`desktop`: a tela esconde nas outras; o app usa a mesma lista), `device` (lista; só o app avalia). Todas as chaves valem juntas (E). O formulário do editor cuida de papel e tela; o resto vem do JSON e fica ao salvar pelo formulário |
| `label`, `icon`, `color` | `color`: `accent`, `amber`, `green`, `red`, `blue` (a cor quando ligado) ou os tokens do tema `ok`, `warn`, `danger`, `info` (acompanham claro/escuro; hex solto não entra, cor própria é pelo tema da casa) |
| `style_if` | lista (1–10) de regras `{when, color, icon, label, tone, badge}`: a primeira cujo `when` bate (as condições do `visible_if`, com `any`/`all`, sem `role`/`screen`/`device`; sem `when` = sempre) vale. Ver "Painel por dado" |
| `stale_after_min` | minutos sem leitura até o selo "dado velho" nos pontos do widget (`bind`/`binds`); `0` desliga; ausente = o padrão do local por tipo |
| `tap` | `toggle` (padrão em liga/desliga), `more_info` (só abre o ponto), `navigate`, `none` |

### Tipos

| Tipo | Props | Mostra |
|---|---|---|
| `tile` | `bind`, `features` (`toggle`/`select`/`slider`) | ponto: liga/desliga, valor, seleção, slider (dimmer/setpoint; `mode: box` = caixa de número), campo de texto/data/hora (comando `set`, tipo pelo `input` do ponto), botão (`command`/`gate`) e botões de ação (`actions`: contador, temporizador). Serve a todos os helpers (F8e) |
| `group` | `binds` (até 8) | lista de pontos com interruptor |
| `stat` | `bind` ou `query`, `aggregate` (`count`/`sum`/`avg`/`min`/`max`/`last`), `attribute?`, `labels?` (`{zero, one, other}`, `%{count}` = o número) | contador ("3 ligados") ou número; também é o tipo dos `badges`. Com `bind` e `attribute` (Lote 5), mostra o atributo do ponto (`points.attrs`, escrito pelo sensor calculado) no lugar do valor |
| `gauge` | `bind`, `min`, `max` (padrão: do ponto, senão 0–100) | medidor em arco |
| `chart` | `binds`, `range` (`24h`/`7d`/`30d`) | linhas na mesma escala (booleano: faixas ligado) |
| `query_list` | `query`, `empty_text`, `or?` (outras consultas somadas, até 30), `display?` (`rows`/`tiles`), `labels?` ({id do ponto → nome}) | lista automática (até 24), em lista ou grade de tiles; `empty_text` `" "` = some quando vazia. `or` e `labels` vêm do auto-entities do HA e ficam ao editar pelo formulário (`QueryListWidget.keep`) |
| `ask` (plugin) | `placeholder?` | "Perguntar à casa" no painel: a pergunta vai para `Ai::Ask` (o mesmo da tela `/perguntar`, só leitura) e a resposta aparece no card (web `POST /perguntar/painel`, no frame do widget; API `POST /api/v1/sites/:id/ask` → `{answer, provider, model}`). Sem provedor de IA ligado, o card leva a Configurações → IA |
| `ai_usage` (plugin) | — | Uso de IA do local (`AiCall`): chamadas hoje, no mês, falhas em 30 dias e, para técnico ou dono, o gasto estimado do mês; abaixo, as automações que mais chamaram em 30 dias |
| `ai_log` (plugin) | `limit?` (3 a 30, padrão 8) | Linha do tempo da IA: as últimas chamadas no formato do Diário (`items` com `at`, `icon`, `tone`, `title`, `state`, `detail`), sem prompt nem resposta |
| `announce` (plugin) | `binds?` (as Echos do seletor; vazio = todas), `placeholder?` | "Falar na Alexa": texto (anúncio), Echo de destino ou todas e microfone (voz gravada até 60 s; só em https). Envio por `Alexa::Talk` (web `POST /locais/:id/falar-na-alexa`, API `POST /api/v1/sites/:id/talk`): a voz vira MP3 (ffmpeg) e a Echo toca `<audio>` do link curto `/fala/<chave>.mp3` em `MEDIA_PUBLIC_URL` (https de fora); sem ele, o microfone some |
| `area_card` | `area`, `facts?` | cartão da área com os itens (`facts`, consultas; sem eles, o padrão do local, que nasce com ligados, abertos, movimento, potência e sem sinal); tocar num item abre a lista dos pontos dele; o resto navega para a view com `area` igual |
| `scene_bar` | `scenes` (ids; vazio = todas) | botões de cena |
| `alerts` | — | alertas abertos com "Ciente" |
| `camera` | `bind` (ponto `stream` de dispositivo `go2rtc`), `live` (padrão true), `snapshot_interval` (2–300 s, padrão 10) | quadro periódico e "Ao vivo" (WebRTC); sem conexão, o aviso no lugar da imagem |
| `vacuum` | `bind` (ponto `vacuum` de dispositivo `xiaomi_miot`) | estado, bateria, aviso de erro, Limpar a casa/Pausar/Parar/Voltar à base, cômodos do mapa em pílulas + ajustes (modo, potência, água, caminho, vezes) e "Limpar selecionados" (`clean_rooms`), base (lavar, secar, esvaziar) e peças com barra; os irmãos do aparelho entram pelo `address.role` |
| `energy` | `binds` (pontos kWh/Wh acumulados ou W/kW, somados), `period` (`today`/`week`/`month`/`cycle`), `cycle_day` (1–28), `tariff` (R$/kWh) **ou** `tariff_point` (ponto, ex. helper Número), `goal` (kWh), `compare` | "Consumo e custo" (F9): consumo, custo, projeção linear até o fim do período, meta, comparação com o mesmo trecho do período anterior e barras por hora (hoje) ou dia, pelos rollups de hora (`Dashboards::Energy`) |
| `heading` | `title` | título |
| `markdown` (plugin) | `text` | Texto com Liquid (Lote 4): o mesmo das automações (`{{ points["sala.luz"].text }}`, `{{ now \| date: "%H:%M" }}`, `{% if %}`, `{{ "state=on tag=luz" \| points_where \| size }}`) e Markdown mínimo (`# título`, `- item`, `**negrito**`, `*itálico*`, linha em branco = parágrafo). Os pontos citados como `points["chave"]` entram nas dependências (o texto se refaz quando mudam); erro de Liquid aparece embaixo do texto |
| `weather` (plugin) | `bind` (ponto `weather` da integração Clima), `forecast` (`daily` padrão, `hourly`, `none`) | condição, temperatura, sensação, umidade, vento e chance de chuva de agora, e 5 dias ou 8 horas de previsão |
| `media` (plugin, Pacote 1) | `bind` (ponto `media`; serve também para o `speaker` da Echo) | situação, título, artista/app, ligar/desligar, anterior/tocar-pausar/próxima, volume −/mudo/+, barra de volume e "Tocar" (`play_media`); só aparecem os controles que o ponto aceita (`Points::Command.commands_for`, cortado pelo `address.supports`). O painel automático e a página do ponto usam este widget para a capacidade `media` (`describe auto:`) |
| `remote` (plugin, Pacote 1) | `bind` (ponto `remote`) | um botão por código aprendido (`send`) e "Aprender botão" (`learn`, até 20 s) para quem comanda |
| `energy_flow` (plugin) | `grid`, `solar`, `battery`, `battery_soc`, `home` (pontos de potência, id ou chave; rede ou solar obrigatório), `grid_invert`, `battery_invert` | fluxo de energia de agora: rede, solar e bateria para a casa, linhas animadas na direção e na velocidade da potência (`EnergyFlowWidget.split`, na ordem do HA: solar → casa → bateria → rede); rede positiva = comprando, bateria positiva = descarregando; sem `home`, a casa é o que sobra; "% da casa sem a rede" |
| `energy_breakdown` (plugin) | `binds` (opcional; vazio = todos os pontos de energia/potência do local, sem helpers), `period` (`today`/`week`/`month`), `limit` (3–20, padrão 8), `tariff` ou `tariff_point` | consumo por aparelho: ranking em kWh com custo e fatia; por aparelho vale o ponto kWh e, sem ele, o de W; o resto vira "Outros" |
| `energy_compare` (plugin) | `binds`, `tariff` ou `tariff_point` | hoje, esta semana e este mês contra o mesmo trecho do período anterior, com barras, variação e custo |
| `map` (plugin) | `track` (padrão true), `height` (180–800 px) | mapa (Leaflet + OpenStreetMap) com pessoas, zonas e o trajeto do dia; só morador para cima recebe os dados (`Maps::MIN_ROLE`; os outros veem o aviso, sem coordenada no JSON) |

Tarifa por horário (tarifa branca): `tariff_point` apontando para um helper
**Tarifa de energia** faz o custo dos widgets de energia sair hora a hora
pelo preço daquela hora (`price_at`); com número ou helper Número, kWh × preço.

### Painel pronto (predefinições)

Painéis do local → **Painel pronto** (`/locais/:id/paineis/prontos`, técnico
ou dono) monta um painel publicado a partir de pontos escolhidos, só com
widgets comuns. A **Energia** pede rede, solar, bateria, carga da bateria,
medidores de consumo, tarifa (helper ou fixa) e meta, e cria: Agora
(`energy_flow` e `energy` do mês com meta, projeção e comparação),
Comparação (`energy` de hoje e `energy_compare`), Por aparelho
(`energy_breakdown`) e Potência (`chart` de 24 h). Predefinição nova =
classe em `Dashboards::Presets` (herda de `Base`: `describe key:, title:,
icon:, description:`, `fields` com `kind` `:point`/`:points`/`:number`/`:text`
e `filter`, `errors(site, form)` e `build(site, form)` → definição) + nome em
`PLUGINS`; a tela e a criação não mudam (spec com `stub_const` em
`spec/requests/paridade_energia_spec.rb`).

`query` (Lote 4: `Points::Query`, o mesmo das expressões e do Liquid):
`capability` (uma ou lista), `state` (`on`: verdadeiro, `open`; `off`: o
resto), `is` (valor em texto), `area` (id ou nome), `device_class` (`power`
também pega medição em W), `tag`, `quality`, `integration` (driver do
aparelho: `tuya_local`, `virtual`…), `device` e `name` (contém),
`exclude` (nome, chave ou aparelho contém; vírgula = vários), `above`/`below`
(número), `unchanged_min` (sem mudar há N minutos), `changed_min` (mudou nos
últimos N minutos), `sort` (`name`, `value`, `changed_at`; `-` na frente =
decrescente) e `limit`. Lista = vírgula ou JSON. Ponto oculto ou desativado
nunca entra.

### Tipo novo de widget (aberto para extensão, Lote 4)

Todos os tipos da tabela acima são plugins (os da F5 também). Widget novo =
classe em `app/services/dashboards/widgets/` (herda de
`Dashboards::Widgets::Base`) + nome em `Dashboards::Widgets::PLUGINS` (a
ordem é a do seletor de tipo) + partial `web/dashboards/widgets/_<tipo>`. A
classe diz `describe type:, label:, icon:, required:, params:, bind:, binds:,
auto:` e, se precisar, `errors(w)` (validação além das props comuns),
`data(resolver, w, binds)` (→ `[data, pontos extras]`, que viram dependência
do tempo real; ponto que o widget desenha entra no `points` por
`resolver.use(p)`; o resolver também dá `site`, `role`, `points`,
`query(q)` e `definition`), `attrs(params, site)` (formulário → props),
`permit` (campos que não são texto simples, ex. `{ "scenes" => [] }`),
`auto_widget(ponto, id)` (o widget do painel automático para o ponto; o
padrão usa `auto:`) e `form` (partial ou lista de partials com os campos
próprios no editor, locals `w`, `uid`, `types` → `data-for="<%= types %>"`;
partial de vários tipos, como o filtro `query` de `stat` e `query_list`,
sai uma vez só). O `Schema` (`types`/`labels`), o `Resolver`, o editor
(tipo, ícone, seletor de ponto, campos), o `Generator` e a tela perguntam ao
registro; nenhum deles tem `case` por tipo.

Ficam para depois (driver ainda não existe ou v1.1): `vacuum`,
`timeline`, `health`, `calendar`, `select`/`slider`/`button`/`gate`
como tipos próprios (hoje cobertos pelo `tile`) e os da indústria.

Cada ponto do `points` resolvido leva também `icon`, `helper`, `commands`
(os que aceita, do plugin se for helper), `actions` (comandos sem valor para
botões), `mode` e `input` (`number`, `text`, `password`, `date`, `time`,
`datetime-local`).

## Resolvido (`GET /api/v1/dashboards/:id`)

A definição publicada (ou o rascunho com `?draft=1`, para quem edita) com:

- widgets que o papel não vê removidos; cada widget ganha `visible` (estado,
  qualidade, hora agora), `data` e `deps`;
- `data` por tipo: `tile`/`group`/`chart`/`camera` → `point_ids`, `missing`; `vacuum` → `point_ids`,
  `rooms`, `actions`, `detail`, `battery`, `fault`, `settings` ({papel → id}), `parts`; `stat` →
  `value`, `unit`, `text`, `point_ids`; `gauge` → `min`, `max`, `ratio`;
  `query_list` → `point_ids`, `count`; `energy` → `kwh`, `cost`, `projection_kwh`,
  `projection_cost`, `tariff`, `goal`, `goal_ratio`, `previous_kwh`, `delta_pct`, `bars`
  ([{at, label, kwh}]), `period_label`, `point_ids`, `missing`; `area_card` → `area`, `view_id`, `facts`
  ([{id, text, icon, tone, value, count, num, url}]), `caption`, `total` e, para o app antigo, `on`,
  `open`, `motion`, `power`, `unavailable` (dos fatos de mesmo id); `stat` também `caption` (dos
  `labels`) e `drill_url` (com consulta); `scene_bar` → `scenes`
  (`can_activate`, `confirm`); `alerts` → `alerts` (`can_ack`);
- `deps`: ids dos pontos cuja mudança muda o widget (o tempo real usa);
- `points`: dicionário id → `{key, name, capability, unit, value, text, on,
  quality, changed_at, risk, confirm, writable, can_command, commands, options,
  min, max, step, device, area_id, title, context, status_note, display_icon}`.
  `title`/`context` seguem `Point#display_names` (regra de exibição: nome
  genérico do ponto cede o título ao aparelho, nome contido no outro não
  repete); `status_note` diz por que está sem sinal ou sem leitura;
  `display_icon` é o ícone que a web usa. O `tile` traz `data.title` e
  `data.context` (o rótulo automático "Aparelho · Ponto" do Início vira título
  + contexto). Soma e média do `stat` ignoram ponto sem sinal. Gráfico: o app
  busca `GET /points/:id/history`;
- widget com `style_if` que bate: as props `color`/`icon`/`label` já trocadas e `style` `{tone, badge}`;
  ponto parado além do limite: `stale` `{since, text, point_ids}`;
- cada visão traz `hero_now` `{title, kicker}` ou `{hide: true}` (o topo resolvido; ver abaixo);
- `role`, `can_edit`, `version`. Resposta com `ETag` (304 se nada mudou).

O comando sai sempre por `POST /points/:id/commands` (papel × risco e
`Points::Command`); o widget só mostra o botão quando `can_command`. Ponto com
risco ou `confirm` pede confirmação na web e deve pedir no app.

## Tempo real na web

`Point#report!` manda, além do *refresh* da página do ponto, um
`<turbo-stream action="point_changed" target="<point_id">` no stream
`[site, :points]` (só o id, nenhum HTML). A tela do dashboard assina esse
stream (`PointsChannel`, exige papel no local) e recarrega só os quadros
(`turbo-frame[data-points~=id]`) que dependem do ponto, em
`GET /paineis/:id/w/:widget_id`, renderizados com o papel de quem vê. O
comando de um widget volta para o próprio quadro. Medição avisa no máximo uma
vez a cada 1,5 s por ponto (`Points::Broadcast`) e a recarga usa a lista de
pontos em cache curto (`docs/desempenho.md`).

## Painéis em Configurações (F8d)

`/configuracoes/paineis`: todos os painéis dos locais que a pessoa vê, com a
coluna Local; criar (por local), editar, duplicar (`POST /paineis/:id/duplicar`,
cópia publicada como v1, fora do menu e do padrão) e excluir. No painel:
`icon` (lista `Dashboard::ICONS`), `sidebar` (mostrar no menu lateral, como no
HA: `Dashboard.sidebar_for(user)` respeita `roles`), `roles` e o padrão por
pessoa ("Abrir no meu Início" = `prefer`).

**Visões (abas)** = as `views` do JSON (existem desde a F5, então os painéis
antigos já são "uma ou mais visões" e nada precisou migrar). Cada visão tem
`title`, `icon`, `path` (opcional, `[a-z0-9-]`, até 40, único no painel; a
URL usa `?view=<path>` e cai no `id` sem caminho) e as seções/widgets. No
editor: adicionar, renomear, ícone, caminho, setas para reordenar e excluir,
tudo no rascunho (publicar/descartar/versões continuam valendo). Na tela as
abas rolam na horizontal no celular (`.dw-tabs`).

## Web

- `/` (Início): painel padrão da pessoa no local dela.
- `/locais/:id/paineis`: lista, novo, "Abrir no meu Início".
- `/paineis/:id` (`?view=`, `?rascunho=1`), `/paineis/:id/editar` (técnico ou
  dono): views, seções e widgets por formulário, setas para reordenar, largura
  por tela, quem vê, pré-visualizar, publicar, descartar, versões; e
  `/paineis/:id/json` (JSON avançado validado).
- `/configuracoes/paineis`: lista da instalação (ver acima).

## Vitrine (uiweb, 2026-11)

### Planta baixa (`floorplan`)

Widget plugin (`Dashboards::Widgets::FloorplanWidget`). Camadas (andares) com
imagem de fundo (enviada no editor: Active Storage em `Dashboard#files`, PNG,
JPG ou WebP até 8 MB, tipo conferido pelos bytes; ou link `https://`/`/`) ou,
sem imagem, os cômodos desenham a planta. Pontos em % (`x`, `y`) e cômodos
em % (`x`, `y`, `w`, `h`, `area`):

```json
{ "type": "floorplan", "layers": [ { "id": "t", "title": "Térreo", "image": "/rails/active_storage/...",
  "pins": [ { "point": "<id>", "x": 22, "y": 30 } ],
  "rooms": [ { "area": "<id>", "x": 2, "y": 4, "w": 52, "h": 66 } ] } ] }
```

O ícone acende com o estado e a cor real (irmão `color` do aparelho,
`Widgets::Base.color_point`) e alterna com um toque (risco/confirmação do
ponto valem); sensores mostram o valor. O cômodo abre a visão da área (ou a
página da área) e fica âmbar com luz acesa. Botão "noite": planta escura com
halo das luzes (padrão = tema escuro; escolha por navegador). No editor,
arrastar os marcadores escreve x/y (a alça do cômodo muda w/h); os números
continuam editáveis pelo teclado. Qualquer campo `upload` do formulário do
editor vira anexo do painel e preenche o `image` irmão (genérico).

### Editor de arrastar e soltar

"Arrume ao vivo" no editor: os widgets reais do rascunho numa tela simulada
(celular 390, tablet 768, computador 1180, encolhida por zoom). Alça para
reordenar e trocar de seção (SortableJS 1.15.6 em `vendor/javascript`) e alça
na borda direita para a largura da tela escolhida. Ops do rascunho (também
por `Accept: application/json`, resposta 204/422/404): `place` (`kind`,
`target`, `index`, `parent`) e `resize` (`kind`, `target`, `screen`,
`cols`). Os formulários e as setas continuam (teclado).

### Cartões vivos

Só CSS e com `prefers-reduced-motion`: luz brilha na cor real (`color_id` no
`data` do `tile`) e no nível do dimmer; ventilador (nome: ventila/fan/exaust)
gira pela velocidade; cortina (cortina/persiana/toldo/blackout, dimmer ou
setpoint) mostra a posição; portão corre as grades; robô percorre o piso
limpando; mídia com capa (`media.image`, link seguro) e equalizador. Estados
vazios ilustrados (`web/shared/_empty_art`, SVG próprio) e esqueleto
(`.dw-skel`).

### Quiosque (tablet de parede)

`?quiosque=1` liga neste aparelho (cookie `ma_kiosk`, 1 ano, httponly);
`?quiosque=0` desliga. Sem menu, cursor some parado, Wake Lock, botão de tela
cheia e protetor de tela (relógio, relógio e clima, câmeras ou fotos do
painel) depois de N minutos; acorda no toque (o toque não aciona nada) ou
quando o ponto de movimento escolhido muda. Ajustes em `PATCH /quiosque`.
Relógio grande e álbum de fotos: ver "Beleza" no fim.

### Busca global (Ctrl+K)

Paleta em todas as telas (Ctrl+K/⌘K ou "Buscar" no menu); sem JS, `/busca`.
Fontes por registro (`Search::SOURCES`: páginas, pontos, cenas, áreas,
painéis, automações), cada uma cortando pelo papel. Verbo no começo vira ação:
apagar/desligar, acender/ligar, alternar (pontos) e ativar/acionar (cenas);
risco e `confirm` do ponto viram a pergunta de confirmação.

### Temas

`Dashboards::Themes::PLUGINS` (Lista Clara, Aurora, Oceano, Floresta, Pôr do
sol, Grafite). No JSON, `theme` no painel e/ou na visão (a visão herda e
troca): `key`, `night` (tema da noite: pelo sol do local ou por horário, ver
"Beleza" no fim), `image` (papel
de parede), `blur` (0 a 40), `glass` (cartões de vidro) e `dark` (a visão
abre no modo escuro, qualquer que seja o da pessoa: papel de parede escuro; a
web troca o `data-theme` do `<html>` enquanto o painel está aberto, o app
desenha a visão com o tema escuro). Galeria no editor (Aparência e "Tema desta
visão", campo Modo).

## Paridade de painéis (ondaB2, 2026-11)

Tudo por registro, com spec de plugin falso em `spec/requests/onda_b2_spec.rb`.

### Tipos de visão e subvisões (`Dashboards::ViewTypes`)

`type` na visão: `sections` (padrão), `masonry` (mosaico em colunas pela
altura), `panel` (o primeiro card na tela inteira) e `sidebar` (seções com
`"position": "sidebar"` na coluna da direita; sem marca, a última). A visão
guarda sempre seções; o tipo só muda o desenho (partial
`web/dashboards/views/_<chave>`; no app `ViewLayouts.register`). Subvisão:
`"subview": true` e `back_path` (caminho ou id): fora das abas, com "Voltar
para" no topo.

### Pilha e grade (`stack`)

`{"type": "stack", "direction": "vertical|horizontal|grid", "columns": 2..4,
"widgets": [...]}`: até 12 widgets dentro, dois níveis. Plugin com
`container?` guarda filhos; Schema, Resolver (cada filho tem o próprio quadro
de tempo real) e editor ("Adicionar dentro", mover, editar sem perder os de
dentro) entendem o aninhamento.

### Visões de cômodo arrumadas (`Dashboards::RoomLayout`)

`bin/rails 'dashboards:comodos[<id do painel>]'` mostra o antes → depois de
cada visão com `area` (`PUBLICAR=1` publica uma versão nova, que volta pelo
histórico). Não comanda nada; rodar de novo não muda o que já está arrumado.
A regra é dado (`Dashboards::Arrange`, ver "Arrumação como dado" no fim); o
padrão (`Arrange::DEFAULT`) é a tabela abaixo (a primeira que vale):

| Vai para | Quando |
|---|---|
| selo do topo (`badges` da visão, `stat` `last` com o nome e o ícone do tile) | `tile`/`stat` de ponto só de leitura de estado: capacidade `contact`/`motion`/`tamper`/`problem` ou classe de porta, janela, movimento, presença, vazamento, fumaça, bateria… (`BADGE_*`); ponto que já tem selo na visão não se repete |
| coluna 1 (ações) | tipo `thermostat`, `light`, `button`, `vacuum`… (`TYPE_COLUMN`) ou ponto gravável fora de mídia |
| coluna 2 (cenas e automações) | `scene_bar` (largura toda fora do celular, uma embaixo da outra), ponto de automação (`AutomationPoints`) ou `script` |
| coluna 3 (mídia e medidas) | `camera`, `chart`, `gauge`, `weather`…, ponto `speaker`/`media`/`stream` e o resto só de leitura (temperatura, potência) |

O título segue o primeiro widget dele que fica numa coluna (sem widget, sai);
coluna vazia não entra e a largura se divide (4/4/4, 6/6, coluna única 6).
O chip de cena nunca passa da largura do widget: nome comprido fica com
reticências (antes, com a quebra de linha da gem, ele vazava sobre o card
vizinho).

### Tile de automação

Ponto de automação (`AutomationPoints`) aceita também o comando `run` (roda
agora a versão publicada, sem as condições, como o `automation.trigger` do HA)
e o ponto resolvido traz `ran_at`. Tile cujo toque é `command` `run` no próprio
ponto vira botão "rodar" com "Rodou há 5 min" no lugar de ligado/desligado; com
o interruptor, o "rodou há" vai ao lado do estado. Tile deitado só em linha
inteira no celular (`span.mobile` 12); em um terço da linha, sem o ⋯.

### Recursos do tile (`Dashboards::TileFeatures`)

`"features": ["brightness", {"type": "climate_mode", "point": "<id>"}]`.
32 recursos (os do HA: luz, cortina, ventilador, clima, umidade, aquecedor,
robô, alarme, fechadura, válvula, opções, número, mídia, ações de helper,
botão, tendência e barra). O alvo é o ponto do tile ou um irmão do aparelho;
o recurso diz o `kind` (`toggle`, `slider`, `stepper`, `chips`, `buttons`,
`trend`, `bar`) e o payload; a web (`web/dashboards/features/_<kind>`) e o
app (`TileFeatureRegistry`) desenham o kind. `toggle`/`select`/`slider`
antigos seguem como controles próprios do tile.

### Ações de toque (`Dashboards::Actions`)

`tap_action`, `hold_action`, `double_tap_action` em qualquer widget que diga
`gestures?` (tile, botão, imagem, relógio): `toggle`, `more_info`,
`navigate` (`navigation_path`: visão ou `/tela`), `url` (só https),
`command` (`point`, `command`, `value`), `assist`, `none`, e
`confirmation` (verdadeiro ou texto). O Resolver põe em `gestures` o que a
tela precisa; web pelo controlador `dw-gesture`, app pelo `DashGestures`.

### Cards novos

`thermostat`, `humidifier` e `light` (mostrador de 270°, alvo, agora, −/+,
modos, liga/desliga, aceitam `features`), `button`, `calendar` (`binds`,
`days`), `todo` (helper Lista), `logbook` (`binds`, `period`, `limit`),
`image` (`image`, `aspect`), `iframe` (`url` https, sandbox), `clock`
(`format`, `seconds`, `show_date`, `size`; fuso do local), `plant`
(`binds`, `limits`) e `utility` (gás e água em m³, `Dashboards::Meter`).
O fluxo de energia aceita `co2` (parcela fóssil, %) e `solar_forecast`
(kWh de hoje); o painel pronto de Energia pede gás, água, CO2 e previsão.

### Temas da casa, tema da pessoa e barra lateral

Configurações → Aparência: temas criados (`DashboardTheme`: cores, papel de
parede, vidro, fonte) com prévia ao vivo, que entram na galeria
(`Dashboards::Themes.all`); o tema da pessoa vale por cima do painel, no
perfil (web e app: `PATCH /api/v1/me` `theme`, `GET /api/v1/themes`) ou só
no aparelho (cookie `ma_theme`); a barra lateral de cada pessoa esconde e
reordena itens (`dashboard_prefs["sidebar"]`; Configurações fica sempre).

## Painéis importados do Home Assistant (2026-11)

Configurações → Integrações → "Migre do HA" → cartão **Painéis do Home
Assistant** (`POST /locais/:id/migrar-do-ha/paineis`, `HaMigrationJob`
fase `dashboards`). `Integrations::HaDashboards` lê pelo WebSocket da
integração `home_assistant` (só leitura) a lista (`get_panels`), a
configuração já resolvida de cada painel (`lovelace/config`, com `!include` e
âncoras expandidos) e os temas (`frontend/get_themes`); imagens `/local/...`
vêm pelo HTTP e ficam anexadas ao painel (`dashboard.files`).

- **Mesma disposição** (`Dashboards::HaImport`): visão → visão (caminho,
  ícone, subvisão e voltar, fundo como `theme.image`, tema do HA virando um
  `DashboardTheme` com vidro), seção → seção (`column_span` sobre
  `max_columns` vira a largura em 12), card → widget na mesma ordem e com a
  mesma largura (`grid_options.columns`). Card do HA novo = entrada em
  `CARDS`; recurso do tile = linha em `FEATURES`; condição = método
  `cond_<nome>`. Sem equivalente: um Texto no lugar e tamanho, e a nota no
  relatório.
- **De-para**: entidade, cena, script (pelo ponto do script) e área pelo
  `ExternalRef` da migração; o par painel ↔ painel fica em
  `dashboard:<url_path>` (importar de novo publica uma versão nova do mesmo).
- **Padrões**: o principal sem "mobile" vira o da web (`site_default`); o
  primeiro com "mobile" vira o do app (`app_default`; a API do app responde
  esse como `default`, e a escolha da pessoa no app é `dashboard_prefs["app:<local>"]`).
- **Ícones do HA** (`mdi:nome`) valem em qualquer card, visão e painel: web
  pelo `Mdi` (vendor/mdi/mdi.json), app pela fonte MaterialDesignIcons.
- **Visibilidade**: `state.not` (o `state_not` do HA) e `all` (todas as
  condições), além do `any`.
- **Outro painel**: `navigation_path` e `back_path` aceitam
  `/paineis/<id>?view=<caminho>` (web e app).

## Painel por dado (11/2026, proposta de personalização P1.1, P1.2, P1.4, ideias 14 e 22)

O painel muda por dado, sem deploy nem versão do app: o servidor resolve e a
web e o app só desenham.

### O que existe (uma regra só)

`Points::Query.exists?(p)`: ponto oculto ou desativado, e aparelho removido da
conta (varredura) ou desativado, não entram. Vale para toda consulta (painel,
cartão de área, Liquid, expressões, sensores calculados) e para o painel
automático.

### Itens do cartão como consultas (`Dashboards::Facts`)

```json
{ "id": "ac", "type": "area_card", "area": "<area>",
  "facts": [ { "id": "abertas", "label": { "zero": "Tudo fechado", "one": "%{count} aberta", "other": "%{count} abertas" },
               "icon": "mdi:door-open", "query": { "capability": "contact", "state": "on" },
               "aggregate": "count", "show": "nonzero", "tone": "warn" } ] }
```

| Campo | Valor |
|---|---|
| `id` | único no cartão (`[a-z0-9_-]`, até 40); vai no caminho da lista |
| `label` | texto (com `%{count}`) ou `{zero, one, other}`; `label_key` = texto da casa em `dashboards.facts.labels.<chave>` (o padrão usa, nos 3 idiomas) |
| `query` | filtros do `Points::Query` (`Points::Query::KEYS`); no cartão de área a `area` entra sozinha |
| `aggregate` | `count` (padrão), `sum`/`avg`/`min`/`max` (só leitura boa, como o `stat`) ou `any` (sim/não) |
| `show` | `nonzero` (padrão: some com 0/nada) ou `always` |
| `tone` | `ok`, `warn`, `danger`, `info` (a pílula tingida) |
| `format` | unidade depois do número (sem ela, a do primeiro ponto) |

Até 8 itens. Sem `facts`, vale o padrão do local: Configurações → Painéis →
"Padrões dos painéis" (`/configuracoes/paineis/padroes/:site_id`, técnico ou
dono), gravado em `sites.settings["dashboard_defaults"]["area_facts"]`; sem nada
gravado, `Facts::AREA_DEFAULTS` (as regras de antes, escritas como dado:
ligados, abertos, movimento, potência, sem sinal com tom `warn`). No editor, o
cartão tem "Usar itens próprios" com o mesmo formulário (que reaproveita o
`widget_forms/_query`). `Facts.resolve(r, facts, scope:, url:)` não sabe de
área: os modelos de card (P1.3) usam o mesmo.

### Estilo condicional (`style_if`, `Dashboards::Style`)

```json
"style_if": [ { "when": { "state": { "point": "sala.porta", "is": "open" }, "time": { "after": "22:00", "before": "06:00" } },
                "tone": "danger", "badge": "Aberta à noite", "icon": "mdi:door-open" } ]
```

Em qualquer widget. Avaliado no `Resolver#decorate` (as mesmas funções do
`visible_if`); os pontos do `when` entram nas dependências do tempo real.
`color`/`icon`/`label` trocam as props do widget (app antigo já desenha);
`tone` e `badge` vão em `style` (web: contorno `.dw-w[data-tone]` e selo
`.ss-badge` no canto `dw-flags`; app: `WidgetDecor`). O formulário do editor
faz regras de um ponto (estado ou faixa) e/ou horário; condição maior (OU,
qualidade) fica como veio e se edita no JSON.

### Topo da visão (`hero`, `Dashboards::Hero`) e selos

```json
{ "id": "home", "title": "Início", "hero": { "title": "{{ points[\"sala.temp\"].text }} na sala", "kicker": "Casa da praia", "greeting": false, "hide": false } }
```

`title`/`kicker` com Liquid (o das automações, até 200 letras; erro mostra o
texto cru). Sem `title`: a saudação ("Boa noite, Ana") na primeira visão do
Início ou com `greeting: true` (`false` desliga), senão o nome da visão. Sem
`kicker`: "local · data". `hide: true` tira o topo (na web fica só o lápis; no
app a barra fica, para trocar de painel). `Hero.apply!` põe `hero_now` em cada
visão (web e `GET /api/v1/dashboards/:id`). O topo não se refaz pelo tempo real
(só ao abrir). Selo (`stat`) com `labels` `{zero, one, other}` sai com
`caption` pronto ("Nada ligado", "1 ligado", "3 ligados"); sem `labels`,
"número rótulo" (acabou o "Nenhum" fixo e o singular por `delete_suffix`).

### Lista dos pontos de um número (ideia 14)

`GET /paineis/:id/w/:widget_id/pontos[?item=<id do fato>]`: os pontos que entram
no número, com o valor, a situação (qualidade + `point_status_note`), a última
leitura e o aparelho (com a situação dele). O plugin do widget diz a lista
(`drill(r, w, key)` → `{title, subtitle?, points}`, nil = sem lista; hoje
`area_card`, `stat` com consulta e `query_list`); o caminho vai no `data`
(`facts[].url`, `drill_url`). No app abre como tela do servidor (AppScreen).

### Dado velho (ideia 22, `Dashboards::Staleness`)

Widget cujo ponto (`bind`/`binds`) está "bom" mas sem leitura (`reported_at`)
há mais que o limite ganha `stale` `{since, text, point_ids}`. Limite:
`stale_after_min` do widget (0 desliga), senão o do local por `device_class`,
capacidade ou `default` (`settings.dashboard_defaults.stale_after_min`,
editável nos Padrões), senão `Staleness::DEFAULTS` (temperatura e umidade,
240 min; sensor que só fala quando muda ficaria "velho" sem estar).

### Pontos de extensão

Item novo de cartão = dado (padrão do local ou `facts`); conta nova =
`Facts::AGGREGATES` + `Facts.value`; regra de estilo = dado; lista de um widget
= `drill` no plugin; tom novo = `Facts::TONES` (web `FLAG_TONES`, app
`serverTone`). O editor JSON por widget e os modelos de card (próxima onda)
validam pelo mesmo `Schema` (`Facts.errors`, `Style.errors`, `Hero.errors`).

## Arrumação como dado (11/2026, proposta de personalização P2.1, ideias 3, 6 e 8)

### Regras (`Dashboards::Arrange`)

Duas listas por local em `sites.settings["dashboard_defaults"]`, editadas em
Configurações → Painéis → **Regras de arrumação**
(`/configuracoes/paineis/arrumacao/:site_id`, técnico ou dono; "Voltar ao
padrão" apaga só estas chaves):

- `arrange` (visões de cômodo, `RoomLayout`); o painel pode ter a sua em
  `definition["arrange"]` (validada pelo `Schema`), que vale no lugar da do local:

  ```json
  { "badges": { "widgets": ["tile", "stat"], "match": [{ "query": { "capability": "contact,motion", "commandable": "false" } }],
                "icons": { "door": "mdi:door" } },
    "columns": [ { "id": "actions", "title": "Comandos", "match": [{ "type": ["light", "thermostat"] }, { "query": { "commandable": "true" } }] },
                 { "id": "scenes", "full": ["scene_bar"], "match": [{ "type": ["scene_bar"] }, { "query": { "automation": "true" } }] },
                 { "id": "media", "match": [{ "query": { "capability": "speaker,media,stream" } }] } ],
    "fallback": "media" }
  ```

  Ordem: coluna cujo `type` tem o tipo do widget; pilha/grade = a do primeiro
  de dentro (nunca vira selo); sem ponto = `fallback`; selo; coluna (na ordem)
  com alguma consulta que o ponto do `bind` satisfaz; `fallback`. Até 4 colunas.
- `auto_rules` (painel automático, `Generator`): `light` (padrão
  `capability=onoff,dimmer tag=iluminacao`; o nome pela regex `LIGHT` só de
  reserva, com `light_names`), `technical` (fica fora das visões), `security`,
  `power` e `power_limit` (medidores no gráfico, 1–8). "Outras áreas" e os
  demais títulos vêm do I18n.

As consultas são as do `Points::Query`, com 4 filtros novos: `commandable`
(gravável e fora de `Point::READ_ONLY`), `not_capability`, `unit` e `risk`;
`automation` passou a valer também para o ponto com `address.automation_id`.
`Points::Query#match?(ponto, consulta)` testa um ponto (sem "o que existe").
O padrão serializado reproduz as regras de antes: o `spec/services/arrumacao_spec.rb`
compara com a cópia congelada do código antigo (`spec/support/legacy/`).
Diferenças de propósito: a etiqueta `iluminacao` também vale no aparelho e na
área (como em toda consulta), ponto do aparelho "Automações" sem
`automation_id` vai para cenas, e pilha que começa com selo vai para a reserva
(antes quebrava).

### No editor (`web/dashboards/_arrange_tools`, `Web::DashboardArrangeController`)

Tudo entra no **rascunho**; nada muda até publicar.

- **Arrumar esta visão** (`GET/POST /paineis/:id/arrumar?view=`): prévia antes →
  depois (`Dashboards::Diff`) e "Aplicar ao rascunho".
- **Visão automática** (ideia 6, `Dashboards::AutoViews`): visão com
  `"auto": {"area": id}` (ou `{"home": true, "areas": [...]}`) se refaz a cada
  leitura (`Dashboard#published`/`#working_draft`), arrumada pelas regras (a não
  ser com `"arrange": false`); aparelho novo entra sozinho. Ids levam o da visão
  na frente (`<visão>--<id>`). "Congelar" (`POST /paineis/:id/congelar`) tira a
  marca e a visão fica como está, normal. Criar: `POST /paineis/:id/visao-automatica`
  com `area_id` (visão nova) ou `view` (a visão com `area` passa a se montar).
- **Montar por frase** (ideia 3, `Dashboards::Compose`, `POST /paineis/:id/montar`):
  a IA da instalação (`Ai::Request`, origem `painel`; nunca IA da suíte) recebe a
  frase, os tipos de widget de um ponto e a lista de pontos do local e devolve
  `{title, sections: [{title, widgets: [{type, point, label}]}]}` (saída
  estruturada quando o provedor tem; senão o JSON do texto). Só ponto do local,
  cada widget conferido pelo `Schema` (senão o widget do aparelho, senão `tile`,
  senão sai e aparece em "Ficaram de fora"). Substitui a visão de mesmo nome ou
  entra no fim; abre **Mudanças** (`GET /paineis/:id/mudancas`: publicado →
  rascunho, com Publicar e Descartar).

### Assistente (ideia 8, `Dashboards::Wizard`)

Cômodos + estilo (`columns` = arrumado pelas regras, `devices` = um bloco por
aparelho) + tema → Início automático (cartões só dos cômodos escolhidos) e
uma visão automática por cômodo. Em Painéis (`/locais/:id/paineis/assistente`,
cria e publica) e na primeira configuração (passo `dashboard`: com todos os
cômodos e "por aparelho", continua o painel automático de sempre).

O app não muda: desenha o resolvido (visão automática chega já montada) e as
telas novas são web lidas pelo `AppScreen`.
## Agilidade do editor (11/2026, proposta de personalização P1.5 e ideias 1, 2, 4, 5, 7, 24 e 25)

Tudo mexe só no **rascunho**; publicar continua explícito (e passa pela revisão).
Controllers: `DashboardsController` (ops do rascunho), `DashboardWidgetsController`
(JSON do widget, gaveta, copiar), `DashboardVersionsController` (desfazer/refazer,
comparar), `DashboardReviewsController` (revisar e publicar), `DashboardAddsController`
(adicionar ao painel) e `DashboardSchemasController`; o comum fica no concern
`DashboardEditing` (`back=painel` = voltar à edição na própria tela).

### JSON de um widget e JSON Schema (P1.5)

- `GET/PATCH /paineis/:id/w/:widget_id/json`: o JSON só do widget (o id fica);
  salvar troca o widget no rascunho (`Editor#replace_widget`) e valida o painel
  inteiro pelo `Dashboards::Schema` (que já chama `Facts.errors`, `Style.errors`,
  `Hero.errors`, `TileFeatures`, `Actions` e o `errors` do plugin). Ao lado, as
  props do tipo (tocar insere a chave no cursor, controller `dw-json`).
- `GET /paineis/schema.json`: JSON Schema 2020-12 gerado do registro
  (`Dashboards::JsonSchema`): `$defs.widget` com `if type = X then widget_X`, e
  cada `widget_X` com `required`, `bind`/`binds` e os `params` do `describe`;
  listas fechadas (cores, agregações, telas, papéis, chaves de consulta, tipos de
  visão) saem das constantes de quem valida. Plugin acrescenta props próprias em
  `schema_props` (padrão `{}`); prop conhecida pelo nome em `JsonSchema.by_name`.
  É descrição para pessoas e ferramentas: quem manda é o `Schema`.

### Editar na própria tela (ideia 1)

`/paineis/:id?editar=1` (técnico+, fora do quiosque; botão de cursor ao lado do
lápis no topo do painel): o rascunho no layout ao vivo do editor (arrastar dentro
e entre seções, alça de largura por tela) e o clique no card abre os ajustes na
gaveta (`Ss::DrawerComponent`, frame `dw-drawer-frame`, `GET .../w/:wid/ajustes`
com o mesmo `_widget_form` e as ferramentas do widget). Formulários com
`back=painel` voltam para cá.

### Adicionar ao painel (ideia 2)

`GET/POST /paineis/adicionar?tipo=point|device|scene|automation&id=` (técnico+
do local da coisa; link na página do ponto, do aparelho, na lista de cenas e no
editor da automação/script publicada). O widget sai do `Dashboards::AddTo`:
ponto = `Widgets.auto_widget` (capacidade, `describe auto:`) ou `tile`; aparelho
= o widget do ponto (um) ou `group` (até 8 que existem); cena = `scene_bar` com
ela; automação = o liga/desliga dela, script = o ponto que roda. Fonte nova =
linha em `AddTo::SOURCES`. A pessoa escolhe painel · visão · seção e o widget
entra no rascunho.

### Copiar e colar (ideia 4)

Área de transferência no servidor, por pessoa (`users.dashboard_prefs["clipboard"]`,
`Dashboards::Clipboard`, até 64 KB, só vale na mesma instalação): `POST
/paineis/:id/copiar` (`kind` widget/section, `target`). Ops do rascunho: `paste`
(widget numa seção/pilha, seção numa visão, ids novos) e `paste_style` (só
`style_if`, `color` e `icon` do widget copiado; os que ele não tem saem do alvo),
e `duplicate` (cópia logo abaixo).

### Desfazer, refazer e comparar (ideia 5)

`dashboard_draft_steps` (`Dashboards::History`): toda gravação do rascunho pelo
editor (`Dashboard#save_draft!`) guarda o de antes (`undo`, com o rótulo da op) e
esvazia o `redo`; `POST /paineis/:id/desfazer|refazer`. `definition` nulo = "sem
rascunho". Até `History::MAX` (40) passos; publicar zera. `GET
/paineis/:id/comparar?a=&b=` (número da versão ou `rascunho`): `Dashboards::Diff`
por visão, seção e widget (nova, saiu, mudou, mudou de lugar entre os irmãos que
ficaram) com as chaves que mudaram lado a lado, e o "voltar" das versões.

### Atalhos e Ctrl+K (ideia 7)

No editor e na edição na tela (controller `dashboard-keys`): Ctrl+Z / Ctrl+Shift+Z
(ou Ctrl+Y), e com um widget escolhido (clique/foco) Ctrl+C, Ctrl+V (na seção
dele), Ctrl+D, Del (com confirmação), Enter (ajustes), Esc; "?" mostra a lista
(`Ss::ShortcutsComponent`, com "g p" revisar, "g c" comparar, "g n" nova visão,
"g e" editar na tela). As teclas enviam os formulários do próprio editor. Na
paleta: o grupo "Painel X" no topo quando o editor está aberto
(`@palette_groups`, lido pelo `web/shared/_palette`) e a fonte
`Search::DashboardActionsSource` ("publicar Casa", "nova visão Casa", "voltar
versão Casa", "desfazer Casa", "editar Casa na tela" e "duplicar <widget>", este
como ação rápida POST no rascunho); precisa de uma palavra da ação, só o nome do
painel continua na fonte de painéis.

### Revisar e publicar: prévia e avisos (ideias 24 e 25)

O "Publicar" do editor leva a `GET /paineis/:id/revisar` (`?view=`, `?tema=light|dark`):
o rascunho em celular (390), tablet (768) e computador (1280) em iframes do
próprio painel (`/paineis/:id?rascunho=1&embed=1&tema=`, layout `embed`: sem
moldura, menu, paleta nem "Falar"; nada renderizado duas vezes), o número de
mudanças (`Diff.count`) e os avisos do `Dashboards::Lint`, que **não bloqueiam**
(a confirmação de publicar diz quantos são), cada um com "Corrigir" (editor na
visão e no widget). O Lint olha pela chave, nunca pelo tipo: ponto citado em
`bind`/`binds`/`point`/`points`/`*_point(s)` em qualquer nível (visible_if,
style_if, gestos) que não existe, está desativado, é de aparelho removido ou
desativado, ou sem leitura há `Lint::SILENT_DAYS` (3) dias; `query` que hoje não
traz ponto; `area`/`scenes` que sumiram.

## Painel do dia a dia (11/2026, proposta de personalização, ideias 9 a 13 e 23)

Tudo resolvido no servidor; a web e o app só desenham. Spec em `spec/requests/experiencia_spec.rb`.

### Contexto: sol, presença, ordem e visão que abre (`Dashboards::Context`)

```json
{ "open_if": [ { "when": { "presence": { "home": "nobody" } }, "view": "fora" } ],
  "views": [ { "id": "home", "title": "Início",
               "order_if": [ { "when": { "sun": { "is": "night" } }, "first": ["s-seguranca", "s-luzes"] } ],
               "sections": [ ... ] } ] }
```

- `visible_if`/`style_if` ganham `sun` (`{is: day|night}` ou `{after, before}` com `sunrise`/`sunset` e
  `after_offset`/`before_offset` em minutos; sem latitude no local, dia = 6h–18h) e `presence`
  (`{home: anyone|nobody|everyone}` sobre os helpers `person`, ou `{person: <ponto>, home: true|false}`;
  sem pessoa cadastrada nenhuma regra de presença vale). As pessoas entram nas dependências do tempo real.
- `order_if` (visão, até 10 regras): a primeira que bate põe as seções de `first` na frente, na ordem dada
  (`order_now` no resolvido). `open_if` (painel): a primeira que bate escolhe a visão (`open_view` no
  resolvido; a web usa quando a URL não pede visão, o app quando a pessoa não escolheu).
- Condição nova = classe em `Context::CONDITIONS` (`key`, `errors`, `ok?(resolver, valor)`, `refs`). O
  Resolver só pergunta ao registro (`condition_ok?` cai no `Context.ok?` para chave que não é dele).
- Ordem e visão valem ao abrir (como o topo); o `visible_if` também se refaz pelo tempo real.

### Painel por aparelho (`PanelDevice`, ideia 10)

"Neste aparelho abre o painel X" (o tablet da parede). Web: cookie assinado `ma_device` criado ao dar nome ao
aparelho em Configurações → Painéis → Aparelhos (`/configuracoes/paineis/aparelhos`); app: cabeçalho
`X-MA-Device` com o id da instalação em todo pedido (também chega às telas do servidor pelo `AppScreen`). Ordem:
`?view=`/`?local=` da URL > aparelho (painel e visão, se a pessoa vê o painel) > escolha da pessoa
(`dashboard_prefs`) > padrão do local. API: `GET /sites/:id/dashboards` marca `device_default` e
`GET /dashboards/:id` devolve a visão do aparelho em `open_view`. Cada pessoa gerencia os aparelhos que nomeou;
dono e administrador, todos. Auditado (`AuditEvent`).

### Link de convidado (`GuestLink`, ideia 11)

Configurações → Painéis → Convidados (`/configuracoes/paineis/convidados`, só o dono do local): nome, painel,
papel `viewer` (só ver) ou `guest` (comando de risco normal) e validade (2 h a 7 dias). O link
`/convidado/<token>` (token só em digest, mostrado uma vez) abre, sem conta e sem menu (layout `guest`), só os
widgets marcados com `"guest": true` (e os de dentro de uma pilha marcada), resolvidos com o papel do link.
Comando só em ponto desses widgets, sem valor (`on`/`off`/`toggle`/`press`/`run`/`pulse`), papel x risco e
**nunca crítico**; vira `Command` com `source: "guest"` e `AuditEvent` `command` no link (criar e revogar
também). Revogar corta na hora; vencido ou revogado = "Link inválido".

### Ações em lote (`Dashboards::Batch`, ideia 12)

Ação `command_query` em `Dashboards::Actions` (gesto `tap/hold/double_tap_action` ou botão rápido):
`{"action": "command_query", "query": "capability=onoff state=on", "command": "off", "value"?}`. Botões rápidos
em qualquer widget: `"quick_actions": [{"action": ..., "label": "Apagar tudo", "icon"?}]` (até 4, qualquer
ação registrada); sem eles, o padrão do local por tipo em `sites.settings.dashboard_defaults.quick_actions`
(o cartão de área tem o formulário em Configurações → Painéis → Padrões). No cartão de área a `area` entra
sozinha na consulta. O resolvido traz `quick` ([{action, label, icon, slot, count, allowed, can_command,
confirm}]). Envio: web `POST /paineis/:id/w/:widget_id/lote` e API
`POST /api/v1/dashboards/:id/widgets/:widget_id/batch` com `slot` (`quick-N`, `tap`, `hold`…): a consulta e o
comando saem da definição publicada, nunca do pedido; ponto que só lê ou não aceita o comando fica de fora;
papel x risco por ponto (o resto é pulado e contado); crítico nunca vai em lote; até 100 pontos; resposta
`{sent, skipped, failed, message}`.

### Busca e favoritos (`Dashboards::Personal`, ideia 13)

Depois do cache (que é por papel), cada widget ganha `search` (rótulo, título, nomes dos pontos, aparelhos e
áreas) e o painel `favorites_now` (pontos favoritos da pessoa neste local, já em `points`).
Favoritos em `users.dashboard_prefs["favorites"]` = {site_id → [ids]} (até 12): web "Favoritar" na página do
ponto (`POST /pontos/:id/favorito`), app pela estrela da folha do ponto (`PUT /api/v1/points/:id/favorite`
`{favorite}`). Painel com `"favorites": false` não mostra a linha. A web filtra pelo `ss-filter` da gem (a busca
aparece com mais de 3 cards), o app pelo mesmo texto.

### Saúde da casa (ideia 23)

Predefinição `HealthPreset` (`/locais/:id/paineis/prontos/health`): selos clicáveis (`stat` com consulta e
`drill`) de sem sinal, bateria baixa (`device_class=battery below=<limite>`, padrão 20) e Wi-Fi fraco
(`device_class=signal_strength below=<limite>`, padrão -75), listas (`query_list`) de cada um e dos pontos sem
leitura recente, e, com a integração Sistema, as falhas de automação em 24 h e as integrações com erro.
## Beleza (11/2026, proposta de personalização: ideias 15 a 18 e 21, P2.4 e P2.5)

Tudo por dado ou por registro; spec em `spec/requests/beleza_spec.rb`.

### Noite pelo sol ou por horário (P2.4) e fundo por hora do dia (ideia 15)

No `theme` (painel ou visão; a visão do cômodo é o "fundo por cômodo"):

```json
"theme": { "key": "aurora", "night": "grafite", "night_by": "sun", "night_from": "19:00", "night_to": "06:00", "dim": 35,
           "backgrounds": [ { "from": "sunrise", "color": "#fde68a", "color2": "#38bdf8" },
                            { "from": "12:00", "image": "/rails/active_storage/..." },
                            { "from": "sunset", "color": "#1e1b4b" } ] }
```

- `Dashboards::Themes.night?`: `night_by: "sun"` (padrão) usa nascer/pôr do sol (`Sun`) com a
  latitude/longitude do local; sem coordenadas (ou sol que não nasce/não se põe), `night_by:
  "window"` ou `night_from`/`night_to` "HH:MM" (padrão `Themes::WINDOW` = 18:00–06:00). O
  `NIGHT` fixo saiu.
- `backgrounds` (até 6): vale a faixa que começou por último hoje (`from` = "HH:MM", `sunrise`
  ou `sunset`); antes da primeira, a última de ontem. `color` = cor lisa, com `color2` =
  degradê (160°), `image` = foto (troca o papel de parede; faixa de cor tira a foto do tema).
- `dim` (0 a 80 %): escurece o fundo à noite (`body.dw-dim`, `--wall-dim`).
- Resolvido (`theme_now` no app): `is_night`, `wall` ({color, color2}) e `dim` (só à noite)
  além do de antes; `image` já é o da faixa. Web: `dw_theme_attrs` → `--wall`, `--wall-img`,
  `dw-night` no `<body>` (a planta abre no modo noite).
- Editor: "Tema" e "Tema desta visão" ganharam "Quando é noite", início/fim, "Escurecer o
  fundo à noite" e as faixas (horário/sol, cor, degradê ou foto enviada).

### Tile com a cor e o brilho reais (ideia 16)

O `tile` resolve `color_id` (a cor do aparelho) e `level_id` (o brilho: o próprio dimmer ou
o dimmer irmão de uma luz liga/desliga, `TileFeatures::Brightness`). Web: `tone:` na cor
real e `level:` (0 a 1, `dw_level`) no `Ss::DeviceTileComponent` (v0.21 da gem); app:
`SsDeviceTile(color:, level:)`.

### Planta como visão principal e visão inicial (ideia 17)

- Tipo de visão `plan` (`ViewTypes::Plan`, "Planta da casa"): a primeira `floorplan` visível
  no topo, largura toda; o resto da visão em seções embaixo. Sem planta, um aviso.
- `start_view` no painel (id de uma visão que não é subvisão): sem `?view=`, a web e o app
  abrem nela (`Dashboards.pick_view`; o resolvido leva `start_view`). Editor: "Abrir o painel
  nesta visão" na visão; tirar a visão limpa a chave.
- Planta ao vivo: o cômodo acende na cor real da primeira lâmpada colorida acesa (`glow_id`
  do cômodo), porta/portão/cortina aberta (`contact`, `gate`, `cover`) tem o marcador próprio
  (`dw-fp-door`) e acena ao abrir; luz acena ao acender. A noite da planta segue a noite do
  local (a escolha manual vale 12 h neste navegador).

### Micro-animações (ideia 18)

`.ss-cue` + `ss_cue_data(kind: :on|:open|:arrive, active:, key:)` da gem (↔ `SsCue` no app):
toca uma vez quando o estado vira ativo, nunca ao abrir a tela, e "menos movimento" desliga.
Usado no tile (ligou/abriu/chegou pela capacidade), nos marcadores da planta e no avatar de
quem chega em casa (`people`). A chave (`key`) é o id do widget/ponto, para o Turbo Frame
que recarrega saber o estado anterior.

### Quiosque refinado (ideia 21)

- "Relógio grande no canto do painel" (opção `clock` do cookie `ma_kiosk`): hora e data
  grandes com o painel aceso (`.ma-kiosk-clock`); o protetor continua com o relógio dele.
- Álbum do protetor: fotos enviadas no próprio quiosque por quem edita o painel
  (`POST /paineis/:id/album`, `DELETE /paineis/:id/album/:file_id`; PNG/JPG/WebP pelos bytes,
  8 MB, até `Dashboard::ALBUM_MAX`). São anexos do painel com `metadata.album`
  (`Dashboard#album`); sem álbum, o protetor "Fotos do álbum" passa as imagens do painel
  (`saver_photos`). App: `GET /api/v1/dashboards/:id/album` → `[{id, url}]`.
- Acordar por movimento: o ponto escolhido acorda o protetor e, aceso, adia o próximo (o
  `point_changed` do local chega para qualquer ponto, esteja ou não no painel).
- Immich: não há app Immich no catálogo (`config/apps/`), então ficou de fora; quando entrar,
  o álbum pode ganhar a fonte dele sem mudar o protetor.

### Card de terceiros só na web (P2.5)

Decisão: **só web**. O JS de terceiros roda no iframe sandbox da web (origem opaca, `integrity`);
num WebView do app teríamos de reproduzir esse isolamento em Android/iOS (sem o token do app
ao alcance, CSP, ponte de estados e comandos), com plugin nativo novo e superfície de ataque
maior que o ganho. Mecanismo genérico: `web_only?` no plugin do widget
(`CustomCardWidget` responde `true`) → `data.web_only` no resolvido, aviso no formulário do
editor e, no app, um cartão com "Abrir na web".

## Modelos de card, painéis prontos como dado e estilos (11/2026, P1.3, P2.2, P2.3, ideias 19 e 20)

### Modelos de card (`Dashboards::CardTemplates`, tabela `card_templates`)

Card novo sem classe Ruby, partial nem widget Dart. O widget
`{ "type": "template", "template": "<chave>", "vars": { ... } }` é resolvido
inteiro no servidor (`TemplateWidget`) para `data` = `{layout, title,
subtitle, icon, image, value, facts[], tone, tap, variant, version}` (mais
`missing_vars` sem entrada obrigatória e `missing` se o modelo sumiu). A web
(`widgets/_template` + um partial por desenho em `template_layouts/`) e o app
(`TemplateCard`) só desenham.

- **Modelo** = `key`, `name`, `description`, `layout`, `params`, `slots`,
  `version` (sobe ao mudar desenho, espaços ou entradas), `source`
  (`package:<chave>`/`library`). Por local (multi-tenant). Embutidos em
  `config/card_templates/*.yml` (`area` = o cartão de área, `ponto`,
  `contagem`); o do local com a mesma chave vale por cima. Embutido não se
  edita: **Duplicar**.
- **`layout`**: só os desenhos que existem no componentes-ui e no app:
  `mosaic` (`Ss::MosaicTileComponent`/`SsMosaicTile`), `tile`
  (`DeviceTileComponent`/`SsDeviceTile`), `row` (`ListItemComponent`/
  `SsListItem`), `chip` (`.ss-badge`/`SsBadge`), `stat`
  (`KpiCardComponent`/`SsKpiCard`). Desenho novo nasce primeiro no
  componentes-ui (ERB + Flutter), depois entra em `LAYOUTS`, num partial e no app.
- **`params`** (até 8): `{key, label, kind: area|point|text|number, required}`.
  No Liquid, `vars.<key>`; área tem `.name .icon .background .points
  .caption .link`, ponto tem o mesmo do `points["k"]` (`.name .text .value
  .quality .unit .device`) mais `.id`.
- **Espaços de texto** (`title`, `subtitle`, `icon`, `image`, `value`):
  texto Liquid (sandbox `Automations::Context`, 300 caracteres); consulta +
  conta (`{query, aggregate, format, label}`, o item do `Dashboards::Facts`);
  ou regras `[{when, value}]` (a condição do `visible_if`, a primeira que bate).
- **`facts`**: lista de itens do `Facts`, ou `{items|from, scope}`
  (`from: "area_defaults"` = o padrão do local; `scope` junta filtros, ex.
  `{"area": "{{ vars.area }}"}`). Tocar num item abre a lista (`drill`).
- **`tone`**: `ok|warn|danger|info`, Liquid que dá um deles, regras, ou consulta
  com `tone` (vale quando o número não é zero).
- **`tap`**: só uma ação do `Dashboards::Actions` (`navigate`, `more_info`,
  `url`, `toggle`/`command` com papel x risco do ponto...). O widget nunca comanda direto.
- Nos espaços de dado (consultas, regras, tap), `{{ vars.x }}` vira o id
  escolhido e `{{ vars.x.y }}` o campo (`Dashboards::Placeholders`).

Tela: Local → Painéis → Prontos → **Modelos de card**
(`/locais/:id/modelos-de-card`, técnico ou dono): lista, duplicar, editar com
**prévia ao vivo** (o formulário envia para `previa` pelo `ss-autosubmit` e só
o quadro da prévia troca; Salvar troca o destino), exportar e remover. No
editor do painel, o tipo "Modelo de card" escolhe o modelo e as entradas
(`widget_forms/_template`).

### Predefinições como dado (P2.2) e biblioteca (ideia 20)

`Dashboards::Presets.all(site)` = as classes (`EnergyPreset` continua) + a
**biblioteca** (`config/dashboard_library/*.yml`, cada arquivo um manifesto de
pacote só com dados: casa minimalista, tablet da cozinha, segurança, saúde da
casa) + os itens `preset` dos pacotes instalados (chave `<pacote>--<item>`).
O item (`DataPreset`) tem `fields` (`kind` `point|points|area|number|text`,
`filter` {capability, device_class, unit, numeric}, `required`, `default`) e a
`definition` com `{{ fields.<campo> }}`. Montar = trocar os marcadores e
validar pelo `Schema`; widget cujos campos ficaram todos vazios sai (campo
opcional), seção vazia sai. Os modelos de card do mesmo manifesto da biblioteca
entram no local ao criar.

### Exportar e importar (P2.3, `Dashboards::Export`)

"Exportar como pacote" no editor do painel (`/paineis/:id/exportar`) e no
modelo (`/locais/:id/modelos-de-card/exportar?key=`) baixa o manifesto. Ids de
ponto e de área viram entradas (como no blueprint): no painel, `fields` do item
`preset` (e os modelos do local que ele usa vão como `card_template`); no
modelo, `params` novos. Ponto citado pela chave dentro de texto Liquid fica como
está. **Importar** (em Painéis prontos e em Modelos de card) envia o arquivo,
instala pelo `Packages.install!` (fonte `arquivo:<nome>`; "procurar versão
nova" não se aplica) e abre o formulário das entradas.

### Estilos de card (ideia 19, `Dashboards::CardStyles`)

`"card_style": "<chave>"` no painel. Cada estilo é um YAML em
`config/card_styles/` (compacto, vidro, foto, minimalista): `web` = tokens do
componentes-ui (só os de `CardStyles::TOKENS`: `--ss-card-bg/-border/-filter/
-pad`, `--ss-radius-card`, `--r-card`, `--shadow-card`, `--ss-gap`), postos no
`<body>`; `app` = `density` (o `SsDensity`) e as marcas `glass`/`flat`/`photo`.
O painel resolvido traz `card_style_now`. No editor, a galeria "Estilo dos
cards" aplica em um clique (`PATCH /paineis/:id/estilo-dos-cards`: versão nova
publicada, e o rascunho também).

### Pontos de extensão

Modelo novo = dado (tabela, pacote ou `config/card_templates`); fonte de itens
por nome = `CardTemplates::FACT_SOURCES`; desenho novo = `LAYOUTS` + partial em
`template_layouts/` + o app (`TemplateCard`), depois do componentes-ui; estilo
novo = um YAML; painel pronto novo = um manifesto na biblioteca ou um item
`preset` de pacote; tipo de item de pacote = `Packages::ITEMS`
(`CardTemplateItem`, `PresetItem`).
