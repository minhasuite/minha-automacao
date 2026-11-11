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
| `label`, `icon`, `color` | `color`: `accent`, `amber`, `green`, `red`, `blue` (a cor quando ligado) |
| `tap` | `toggle` (padrão em liga/desliga), `more_info` (só abre o ponto), `navigate`, `none` |

### Tipos

| Tipo | Props | Mostra |
|---|---|---|
| `tile` | `bind`, `features` (`toggle`/`select`/`slider`) | ponto: liga/desliga, valor, seleção, slider (dimmer/setpoint; `mode: box` = caixa de número), campo de texto/data/hora (comando `set`, tipo pelo `input` do ponto), botão (`command`/`gate`) e botões de ação (`actions`: contador, temporizador). Serve a todos os helpers (F8e) |
| `group` | `binds` (até 8) | lista de pontos com interruptor |
| `stat` | `bind` ou `query`, `aggregate` (`count`/`sum`/`avg`/`min`/`max`/`last`), `attribute?` | contador ("3 ligados") ou número; também é o tipo dos `badges`. Com `bind` e `attribute` (Lote 5), mostra o atributo do ponto (`points.attrs`, escrito pelo sensor calculado) no lugar do valor |
| `gauge` | `bind`, `min`, `max` (padrão: do ponto, senão 0–100) | medidor em arco |
| `chart` | `binds`, `range` (`24h`/`7d`/`30d`) | linhas na mesma escala (booleano: faixas ligado) |
| `query_list` | `query`, `empty_text`, `or?` (outras consultas somadas, até 30), `display?` (`rows`/`tiles`), `labels?` ({id do ponto → nome}) | lista automática (até 24), em lista ou grade de tiles; `empty_text` `" "` = some quando vazia. `or` e `labels` vêm do auto-entities do HA e ficam ao editar pelo formulário (`QueryListWidget.keep`) |
| `ask` (plugin) | `placeholder?` | "Perguntar à casa" no painel: a pergunta vai para `Ai::Ask` (o mesmo da tela `/perguntar`, só leitura) e a resposta aparece no card (web `POST /perguntar/painel`, no frame do widget; API `POST /api/v1/sites/:id/ask` → `{answer, provider, model}`). Sem provedor de IA ligado, o card leva a Configurações → IA |
| `ai_usage` (plugin) | — | Uso de IA do local (`AiCall`): chamadas hoje, no mês, falhas em 30 dias e, para técnico ou dono, o gasto estimado do mês; abaixo, as automações que mais chamaram em 30 dias |
| `ai_log` (plugin) | `limit?` (3 a 30, padrão 8) | Linha do tempo da IA: as últimas chamadas no formato do Diário (`items` com `at`, `icon`, `tone`, `title`, `state`, `detail`), sem prompt nem resposta |
| `announce` (plugin) | `binds?` (as Echos do seletor; vazio = todas), `placeholder?` | "Falar na Alexa": texto (anúncio), Echo de destino ou todas e microfone (voz gravada até 60 s; só em https). Envio por `Alexa::Talk` (web `POST /locais/:id/falar-na-alexa`, API `POST /api/v1/sites/:id/talk`): a voz vira MP3 (ffmpeg) e a Echo toca `<audio>` do link curto `/fala/<chave>.mp3` em `MEDIA_PUBLIC_URL` (https de fora); sem ele, o microfone some |
| `area_card` | `area` | cartão da área com ligados, abertos, movimento, potência, sem sinal; navega para a view com `area` igual |
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
  ([{at, label, kwh}]), `period_label`, `point_ids`, `missing`; `area_card` → `area`, `view_id`, `on`,
  `open`, `motion`, `power`, `unavailable`, `total`; `scene_bar` → `scenes`
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

### Busca global (Ctrl+K)

Paleta em todas as telas (Ctrl+K/⌘K ou "Buscar" no menu); sem JS, `/busca`.
Fontes por registro (`Search::SOURCES`: páginas, pontos, cenas, áreas,
painéis, automações), cada uma cortando pelo papel. Verbo no começo vira ação:
apagar/desligar, acender/ligar, alternar (pontos) e ativar/acionar (cenas);
risco e `confirm` do ponto viram a pergunta de confirmação.

### Temas

`Dashboards::Themes::PLUGINS` (Lista Clara, Aurora, Oceano, Floresta, Pôr do
sol, Grafite). No JSON, `theme` no painel e/ou na visão (a visão herda e
troca): `key`, `night` (tema das 18h às 6h no fuso do local), `image` (papel
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
A regra é tabela, não lista de pontos (a primeira que vale):

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
