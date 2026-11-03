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
