# Alexa Smart Home (F9): criar a skill e a Lambda

Objetivo: falar "Alexa, liga a luz da sala" e a Minha Automação atender, sem
Home Assistant e sem Nabu Casa. A Amazon exige uma skill **Smart Home** com
uma **Lambda** na AWS; a Lambda daqui (`alexa-skill/index.mjs`) só repassa a
diretiva para `https://casa-automacao.minhasuite.com/alexa/smart_home`. Tudo
o mais (descoberta, estado, comando, papel x risco) é o servidor da casa.

Nada disto é feito pelo sistema na sua conta Amazon/AWS: siga os passos.

## Como funciona

- **Vínculo (account linking)**: OAuth 2.0 "authorization code". A Amazon
  abre `/oauth/autorizar` do servidor; você entra, escolhe o **local** e
  permite. O código (5 min, uso único) é trocado em `/oauth/token` por um
  token de 30 min + refresh de 60 dias (renovado sozinho pela Amazon). O
  vínculo é um `ApiToken` de cliente `alexa`, preso ao local: não abre a API
  do app, e o token do app não abre a Alexa.
- **O que a Alexa vê**: só o que está marcado em **Local → Alexa** ("Expor
  para a Alexa", desligado por padrão), com o nome falado opcional.
- **Comando**: pelo `Points::Command`, com o papel de quem vinculou x risco do
  ponto (`source: "alexa"` na trilha de comandos).
- **Interfaces** (registro `Alexa::SmartHome::Interfaces`, nada de `case` por
  capacidade fora dele):

| Ponto | Interface | Fala |
|---|---|---|
| liga/desliga | PowerController (LIGHT se o nome parece luz, senão SWITCH) | "liga a luz da sala" |
| intensidade | BrightnessController | "põe a luz em 50%" |
| valor ajustável em % | PercentageController | "põe a persiana em 30%" |
| valor ajustável em °C | ThermostatController (só a temperatura alvo) | "põe o alvo em 23 graus" |
| outro valor ajustável (helper Número) | RangeController (`Ponto.Valor`) | "põe minutos de rega em 20" |
| portão | LockController (trancar = fechar) | "tranca o portão" |
| cena ou script | SceneController | "liga modo cinema" |

**Críticos** (portão, sirene, fechadura, alarme): só são expostos com a caixa
"Confirmo expor" marcada (vira `AuditEvent`). No portão (LockController) a
Alexa pede o **código de voz** para destrancar, se você ligar isso no app da
Alexa (Dispositivos → o portão → Configurações → Destrancar por voz → criar o
código). Nas outras interfaces a Alexa não oferece PIN: pense bem antes de
expor sirene ou alarme.

## 1. Cliente OAuth no servidor

1. Na web da casa: **Locais → Casa → Alexa**.
2. Em "Skill (Developer Console)" clique **Gerar cliente**. Copie o **Client
   Secret** na hora (não aparece de novo) e o **Client ID**. As URLs de
   autorização e de token também estão ali.

## 2. Skill no Amazon Developer Console

1. <https://developer.amazon.com/alexa/console/ask> → **Create Skill**.
2. Nome "Minha Automação", idioma **Portuguese (BR)**, tipo **Smart Home**,
   método **Provision your own** → Create.
3. Anote o **Skill ID** (`amzn1.ask.skill...`).
4. **Account Linking** (menu lateral):
   - Authorization URI: `https://casa-automacao.minhasuite.com/oauth/autorizar`
   - Access Token URI: `https://casa-automacao.minhasuite.com/oauth/token`
   - Client ID / Client Secret: os do passo 1
   - Authentication Scheme: **HTTP Basic (Recommended)**
   - Scope: `casa` (qualquer texto; o local é escolhido na tela de autorização)
   - Salve. Copie as **Alexa Redirect URLs** (três, `https://...amazon.com/api/skill/link/...`).
5. Volte à tela **Alexa** da casa, cole as Redirect URLs (uma por linha) e
   **Salvar URLs**.

## 3. Lambda na AWS

1. <https://console.aws.amazon.com/lambda>, região **US East (N. Virginia)
   us-east-1** (a do Brasil para skills Smart Home).
2. **Create function** → Author from scratch → nome `minha-automacao-alexa`,
   runtime **Node.js 20.x** (ou mais novo), arquitetura arm64 → Create.
3. Em Code, troque o `index.mjs` pelo de `alexa-skill/index.mjs` deste repo
   → **Deploy**. (Opcional: variável `MA_URL` se o endereço público mudar.)
4. Configuration → General → Timeout **8 s**.
5. **Add trigger** → **Alexa** → **Alexa Smart Home** → Skill ID do passo 2.3.
6. Copie o **ARN** da função (canto superior direito).

## 4. Ligar a skill à Lambda

1. No Developer Console, aba **Smart Home** → Default endpoint = ARN da
   Lambda (o mesmo em "North America" se pedir) → Save.
2. Aba **Test** → "Development". A skill fica só na sua conta (não precisa
   publicar).

## 5. Vincular e descobrir

1. Na tela **Alexa** da casa, marque o que expor (comece pela luz "Monitor 2"
   para testar) → Salvar.
2. App da Alexa → Mais → Skills e jogos → Suas skills → Dev → **Minha
   Automação** → Ativar → entra na tela da casa → escolha o local → Permitir.
3. "Alexa, descobrir dispositivos". Teste: "Alexa, liga o Monitor 2".
4. Mudou o que está exposto? "Alexa, descobrir dispositivos" de novo.
5. Desfazer: "Desvincular" na tela Alexa (ou desativar a skill no app).

## Testar sem a Alexa (curl)

Com um token de teste (rails runner, só para o local `Casa`):

```bash
TOKEN=...   # ApiToken.alexa_code! + ApiToken.redeem_alexa_code (ver spec/requests/f9_alexa_spec.rb)
curl -s https://casa-automacao.minhasuite.com/alexa/smart_home -H 'Content-Type: application/json' -d '{
  "directive": {"header": {"namespace": "Alexa.Discovery", "name": "Discover", "payloadVersion": "3", "messageId": "1"},
                "payload": {"scope": {"type": "BearerToken", "token": "'$TOKEN'"}}}}'
```

Revogue o token de teste no fim (`ApiToken#revoke!` ou "Desvincular").

## Problemas comuns

- **"Não foi possível vincular"**: a Redirect URL da Amazon não está salva na
  tela Alexa, ou o segredo foi refeito depois de configurar a skill.
- **Dispositivo "não responde"**: o servidor da casa ou o túnel caiu (a
  Lambda devolve `ENDPOINT_UNREACHABLE`), ou o aparelho está indisponível.
- **"Seu papel não permite"** (`INSUFFICIENT_PERMISSIONS`): quem vinculou não
  tem papel para o risco do ponto (crítico exige morador ou mais).
- Log da Lambda: CloudWatch → Log groups → `/aws/lambda/minha-automacao-alexa`.
