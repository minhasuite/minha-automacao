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
| `query_list` | `query`, `empty_text` | lista automática (até 24) |
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
comando de um widget volta para o próprio quadro.

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
de parede), `blur` (0 a 40) e `glass` (cartões de vidro). Galeria no editor
(Aparência e "Tema desta visão").
