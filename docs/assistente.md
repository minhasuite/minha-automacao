# Assistente de voz (Pacote 3)

O Assist do HA: microfone (web e app) → STT da instalação (capacidade `stt`
de `Ai::CAPABILITIES`) → intenção local → resposta em texto e, se houver
provedor `tts`, fala.

## Fluxo

1. Web: botão **Falar** no topo do painel (`web/assist/_button`, Stimulus
   `assist`). Grava com `MediaRecorder` (só em https/localhost; em http da
   rede de casa, escreva o texto) e manda para `POST /assistente`.
   App: botão de microfone no Início → `POST /api/v1/sites/:id/assist`.
2. `Assist.transcribe` (áudio → texto) e `Assist.call(site:, user:, text:, speak:)`.
3. Intenções de `Assist::INTENTS` (ondaB1), na ordem, sobre a frase
   normalizada (sem acento, minúsculas), no idioma do pedido, do local ou da
   tela (pt-BR, en, es): ligar/desligar/alternar, brilho (número ou
   mais/menos), cor, temperatura (ajustar e "qual a temperatura"), cortina
   (abrir, fechar, posição), mídia (pausar, continuar, próxima, anterior,
   volume, tocar), robô (limpar, voltar à base), timers (criar, quanto falta,
   pausar, continuar, cancelar; `AssistTimer`, fim = evento
   `assist_timer_finished`), listas (adicionar, marcar, ler), estado (ler,
   sim/não, quais/quantos), cena ou script, hora, data, tempo, anúncio nas
   caixas e "deixa pra lá".
   O alvo é resolvido por `Assist.find_points`: nome, apelidos, apelido
   falado (Alexa), "ponto da área" nos três idiomas, área ou andar inteiro e,
   por último, todas as palavras (plural vira singular). Com a área do
   satélite, o que está nela ganha. Brilho, cor e ajuste usam o ponto irmão
   do mesmo aparelho (`Assist.targets`).
4. Nenhuma reconheceu: "Perguntar à casa" (`Ai::Ask`, só leitura). Sem IA
   configurada, responde que não entendeu.

## Frases-modelo

O formato do HA (hassil): `[opcional]`, `(um|outro)` e `{slot}`;
`Assist::Sentences` vira Regexp sobre a frase normalizada. Palavra literal
casa inteira; slot de número (`numbers:`) só aceita algarismos.

## Frases do usuário (gatilho por frase)

Gatilho de automação "Frase dita ao assistente" (`conversation`, o do HA):
uma frase-modelo por linha, em qualquer idioma, com `{slot}`. A intenção
`Conversation` vem antes das nativas: casa, dispara a automação
(`{{ trigger.sentence }}`, `{{ trigger.slots.x }}`) e responde a resposta do
gatilho com `{slot}` trocado. Papel x risco pelo maior risco do que a
automação comanda; crítico nunca por voz.

## Frases e respostas da casa (P3)

Sem automação: aba **Da casa** do Assistente de voz. Frase → cena ou script
(`AssistCustomIntent`, intenção `custom`, antes das nativas; crítico nunca,
sombra do local) e resposta própria no lugar da padrão de qualquer intenção
(`AssistCustomResponse`, por idioma). Detalhes em `personalizacao.md`.

## IA que controla a casa (agente do pipeline)

Agente "local" (padrão): intenções e, se nenhuma reconhecer, o "Perguntar à
casa" só leitura. "local_llm": intenções e, se não reconhecer, a IA com
ferramentas (`Assist::Llm`); "llm": só a IA. Qualquer provedor de
`Ai::PROVIDERS` com saída estruturada serve: o modelo devolve
`{say, calls: [{tool, args}]}`, cada ferramenta é uma intenção
(`Assist::Intent.tool`) e roda com o papel x risco de quem fala, até 3
voltas. O modelo vê só os pontos expostos ao Assist. `conversation_id`
continua a conversa (últimas falas em cache por 5 min).

## Pipelines e depuração

Local → Assistente de voz (`/locais/:id/assistente`, técnico ou dono):
- **Pipelines** (`AssistPipeline`): nome, idioma, agente, IA, e o motor de
  cada etapa (STT, TTS, palavra de ativação) do registro `Assist::Engines`
  (`installation` = a IA da instalação; Wyoming na B6). O preferido atende o
  botão Falar, o app e os satélites sem pipeline. `pipeline_id` no pedido
  escolhe outro.
- **Depuração** (`AssistRun`): as últimas 100 execuções do local com cada
  etapa (motor, tempo, texto, intenção, slots, erro). Áudio nunca é guardado.
- **Frases**: testa uma frase (qual intenção e slots, sem executar), testa uma
  frase-modelo contra um exemplo e lista as frases nativas no idioma.

`Assist::Pipeline.run` é a entrada única (web, app, satélite, MCP).
Motor novo = subclasse de `Assist::Engines::Base` (`describe key:, label:,
kinds:, fields:` + `transcribe`/`speak`/`detect`/`check`) e o nome em
`Assist::Engines::PLUGINS`; prova com `stub_const` no spec da ondaB1.

## Wyoming, palavra de ativação e satélites

- `Wyoming` (cliente do protocolo do HA, TCP curto com timeout): `describe`,
  `transcribe` (Whisper), `synthesize` (Piper), `detect` (openWakeWord), WAV
  ↔ PCM. Motor `wyoming` (`Assist::Engines::WyomingServer`) para STT, TTS e
  palavra de ativação no pipeline. O botão Falar grava WAV 16 kHz mono.
- Containers opcionais no `docker-compose.local.yml`, perfil `voz`
  (desligado): `wyoming-whisper`, `wyoming-piper`, `wyoming-openwakeword`.
- Satélites (`AssistSatellite`, aba Satélites): área, pipeline, papel (no
  máximo morador) e tipo do registro `Assist::Satellites`:
  `wyoming` (wyoming-satellite na porta 10700: run-pipeline → áudio → fim
  da fala por volume → STT → intenção → transcript/synthesize e a fala em PCM;
  começando na palavra de ativação, o áudio passa pelo motor `wake` do
  pipeline) e `esphome` (Voice PE pela API nativa do aparelho integrado:
  áudio pela API, eventos do pipeline e a fala por URL, `ASSIST_MEDIA_URL` ou
  `http://APP_HOST`). O `Assist::Satellites::Listener` sobe no worker
  (`ASSIST_SATELLITES=off` desliga). Fim da fala: `ASSIST_VAD_RMS`.

## Voz offline (local primeiro, voz-offline)

A casa entende e responde sem internet: o microfone vai ao Whisper da rede,
as intenções rodam no próprio servidor e a resposta sai pelo Piper.

### Pipeline

- **Motor Automático** (`Assist::Engines::Auto`, chave `auto`, padrão de
  STT e TTS quando o pipeline não escolhe outro — e quando não há pipeline):
  tenta as contas de voz **locais** (provedor com `local: true` em
  `Ai::Providers::Base`: Wyoming, Voz local) e, se nenhuma responder, as da
  **nuvem** (OpenAI, Gemini; a padrão primeiro) — só se o pipeline deixar
  (`assist_pipelines.cloud`, "Pode usar a nuvem…") e houver internet. A
  etapa da Depuração guarda quem atendeu (`provider`, `where` local/nuvem).
  Sem conta de voz nenhuma, cai no caminho de antes (IA da instalação).
- **Entendimento**: intenções locais (`Assist::INTENTS` + frases da casa)
  primeiro. Não reconheceu: a IA só entra se alcançável agora
  (`Assist.ai_provider`): a pedida/padrão se for da rede da casa (Ollama) ou
  da nuvem com internet e `cloud`; senão a primeira local; senão a resposta
  "Estou sem internet: entendo só os comandos da casa" (intenção `offline`)
  na hora, sem esperar a rede. Agente **"Só os comandos da casa"**
  (`intents`) nunca usa IA.
- `cloud` desmarcado = nada sai da casa: STT, TTS e IA só da rede local.

### Internet e "modo offline"

`Internet.online?`: HEAD curto (2 s) em `INTERNET_CHECK_URL` (padrão
`https://connectivitycheck.gstatic.com/generate_204`), resposta guardada 60 s
no processo. `MA_OFFLINE=1` força o modo offline (para testar a casa sem
nuvem). `Assist::Status.for(site, pipeline)` diz `offline`, `cloud` e o modo
de cada etapa (`local`/`cloud`/`none`; IA também `off`):
- web: o diálogo "Falar com a casa" pergunta `GET /assistente/estado` ao abrir
  e mostra o selo **Modo offline**; toda resposta do `POST /assistente` traz
  `offline` (e `stages`).
- app: `GET /api/v1/sites/:id/assist/status` e o `offline` da resposta do
  `POST /api/v1/sites/:id/assist`; o `AssistSheet` mostra o selo. O app grava
  em **WAV 16 kHz mono** (o Whisper do Wyoming não lê AAC).

### Aba Testar

Local → Assistente de voz → **Testar** (`POST /locais/:id/assistente/testar`,
sem Turbo): grave (WAV pelo `assist-test` / `controllers/voice/wav_recorder.js`)
ou escreva, escolha o pipeline e veja o que ouviu, a intenção, os slots, a
resposta, a fala e o **tempo de cada etapa** (motor, provedor, local/nuvem).
Sem "Executar de verdade" só reconhece (`Assist::Pipeline.run(execute:
false)`, nada é comandado; a intenção que só casa pela forma é recusada por
`Intent.accepts?`). "Verificar a voz local" pergunta `describe` aos
servidores Wyoming das contas e do pipeline (tempo de resposta e modelos).
A execução vai para a Depuração com origem "Teste".

**Tempo de resposta** (`Assist::Latency`): mediana e p95 de STT, intenção,
TTS e total das últimas execuções sem erro, na aba Testar e na Depuração.
Referência medida no spec: a intenção com ~60 pontos fica em poucos ms
(limite do spec: < 1 s); o que pesa é o STT.

### Intenções sem IA (o que entende)

- Cortesia e palavra de ativação no começo saem antes das intenções
  (`Assist::LEAD`: "ok casa", "por favor", "pode", "você pode", "me diga se"…).
- **Tipos falados** (`Assist::Kinds`, dado): "as luzes da sala", "janelas",
  "o ventilador do quarto", "tomadas", "portas", "cortinas", "tv", sem ponto
  com esse nome — por capacidade, `device_class`, rótulo ou parte do nome.
  O local soma ou troca tipos em `sites.settings["assist_kinds"]` (mesmo
  formato de `Kinds::DEFAULT`).
- Estado com o verbo antes: "está aberta a porta da cozinha?".
- Continuam: nome, apelidos (`alias_list`), área e andar, "qual a
  temperatura da sala", cenas e scripts, timers, listas, mídia, cortinas.
- Ajuste do aparelho com liga/desliga que não é o aparelho (luz de fundo,
  luz indicadora, trava infantil, modo privacidade…) nunca conta como tipo
  ("as luzes do escritório") nem entra no cômodo inteiro ("desligue o
  escritório"): lista `Assist::Kinds::SETTINGS` pelo nome do ponto; o local
  soma nomes em `sites.settings["assist_settings"]`. Pelo nome exato continua
  valendo ("desligue a luz indicadora").
- **"Qual delas?"** (`Assist::Clarify`): pedido no singular ("desligue a luz
  do escritório") que casa com vários pontos pelo tipo ou por parte do nome
  não executa: a casa lista as opções e guarda o pedido por 60 s, pela
  conversa (`conversation_id`) ou, sem ela, pela pessoa/satélite. A próxima
  frase escolhe pelo nome ("a do teto", "monitor 1"), pela ordem ("a
  segunda", "2"), "todas" ou "cancela"; outra frase que não escolhe repete as
  opções, e um pedido novo descarta a pergunta. Plural ("as luzes"), cômodo
  inteiro e nome exato fazem direto. O apelido do ponto conta para o tipo
  ("luz do teto" faz o interruptor ser luz).

### Recomendação para o servidor da casa (HP: 4 núcleos, 7,6 GB)

O integrador instala (Configurações → Aplicativos → Whisper e Piper →
Conectar); nada disto é instalado sozinho.

Medido no HP em 13/11/2026 (Intel i3 M 350 de 2010, sem AVX: o Whisper vai
bem mais devagar que numa CPU atual), frase de 2 s gerada pelo Piper:

| Peça | Escolha | RAM (aprox.) | Medido no HP |
|---|---|---|---|
| Whisper `tiny-int8` (pt, padrão do catálogo, `--beam-size 1`) | comandos curtos | ~200–300 MB | ~2,3–2,8 s |
| Whisper `base-int8` (`--beam-size 1`) | entende um pouco melhor | ~300–400 MB | ~6 s |
| Whisper `small-int8` | **não** use no HP | ~0,9–1,1 GB | ~16 s |
| Piper `pt_BR-faber-medium` (padrão) | voz natural | ~150–250 MB | ~0,6 s (2 s de fala) |

- O catálogo sobe o Whisper com `--model tiny-int8 --language pt --beam-size 1`.
  Num servidor com CPU atual (com AVX2), `small-int8` cabe no tempo e entende
  melhor nomes e frases longas.
- Com MA + Postgres + go2rtc + Zigbee2MQTT (~2,5–3 GB), Whisper tiny +
  Piper somam ~0,5 GB: cabe nos 7,6 GB com folga para o cache do disco. Não
  rode Ollama junto no HP (um modelo de 1,5 B já pede ~1,5–2 GB e segundos
  por resposta): sem IA local, deixe o agente "Só os comandos da casa" ou
  "Local" (a IA da nuvem entra só com internet).
- Os números acima são estimativas para CPU x86 de 4 núcleos sem GPU: meça
  na aba Testar (mediana e p95) depois de instalar.

### Testar sem internet

Specs (`spec/services/voz_offline_spec.rb`, `spec/requests/voz_offline_spec.rb`)
derrubam a verificação de internet e a nuvem pela WebMock (HEAD com tempo
esgotado, Anthropic/OpenAI/Gemini com erro de rede) e conferem que nenhum
pedido saiu: fala → Whisper local → intenção → Piper, frase livre → "modo
offline", sem voz local → erro claro. Wyoming por stub; nunca provedor real.
Na casa: `MA_OFFLINE=1` no `.env` (ou tire o cabo da internet do roteador) e
use a aba Testar.

## Servidor MCP

`POST /mcp` (JSON-RPC 2.0, transporte "streamable HTTP" sem SSE; `GET` =
405), com `Authorization: Bearer ma_mcp_...`: token de longa duração (1 ano)
de uma pessoa num local, criado na aba MCP (aparece uma vez; revogável;
`ApiToken` com `client: "mcp"`). Métodos: `initialize`, `ping`,
`tools/list`, `tools/call`, `resources/list`, `prompts/list` e lote.
Ferramentas = as intenções com `tool` (as mesmas da IA) + `get_live_context`
(estado dos pontos expostos). Roda com o papel x risco da pessoa, só o
exposto ao Assist, crítico nunca; cada chamada fica na Depuração (origem MCP).

## Segurança

- Comando por voz usa `source: "voice"` e o usuário que falou; segue o papel
  x risco dele; **ponto ou cena crítica nunca por voz**.
- Respeita a sombra do local (`Shadow.for_site`): aparelho não recebe nada.
- Chave de integração não usa o assistente.
- A fala gerada é anexo com URL assinada de 1 dia (`Ai::Audio.store`).
- Chamadas de IA ficam em `AiCall` com origem "voz" (sem áudio nem texto).

## Estender

Intenção nova = subclasse de `Assist::Intent` com
`describe key:, description:, sentences: {"pt-BR" => [...], "en" => [...], "es" => [...]}, slots:, numbers:`,
`handle(ctx, slots)` → `Reply` ou nil (a próxima tenta), textos en/es por
`texts`, e o nome em `INTENTS`. A mesma intenção vira ferramenta da IA e do
MCP (`tool`). Prova com `stub_const` em `spec/services/onda_b1_spec.rb`.
Plugin antigo (só `pattern`, em pt) continua valendo.
