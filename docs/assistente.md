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
