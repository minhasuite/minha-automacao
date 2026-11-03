# Entrar com Google (web e app)

Padrão da suíte (Minhas Vendas, Minhas Viagens, Meu Cultivo): o Google entrega
um **id_token** e o servidor troca por sessão (web) ou pelo token do Minha
Automação (app). Sem `GOOGLE_CLIENT_ID`, nada aparece.

## Como funciona

- **Web** (`/entrar`, `/criar-conta`, `/convite/:token`, primeira
  configuração): botão do Google Identity Services (controller Stimulus
  `google-signin`), que posta o `credential` em `POST /entrar/google` com o
  CSRF do Rails. O botão some sem client e quando o endereço é IP ou `.local`,
  porque o Google só aceita origem https com domínio (ou `localhost`).
- **App**: `GET /api/v1/auth/providers` diz o client web do servidor
  (`google_client_id`, nulo = sem botão). O app usa esse valor como
  `serverClientId` do `google_sign_in` e manda o token em
  `POST /api/v1/auth/google {id_token, otp?, invite_token?, device_name?}` →
  `{access_token, refresh_token, user}`.
- **Conferência** (`GoogleLogin.verify!`, gem `googleauth`): assinatura pelas
  chaves públicas do Google, `iss`, validade, `aud` ∈ client(s) configurados e
  `email_verified = true`.
- **Conta**: acha pelo Google vinculado (`users.google_uid`) ou pelo e-mail
  verificado (e vincula). Um e-mail cuja conta já está vinculada a **outro**
  Google é recusado. Sem conta: com convite, ela nasce na instalação do
  convite, com o papel dele, e o link é usado; sem convite, nasce uma instalação
  nova (igual a "Criar conta"). Na instalação vazia, o Google cria o dono.
- **Duas etapas**: com TOTP ligado, a web leva para `/entrar/codigo` e a API
  responde `401 mfa_required`. O app pede o código e repete com `otp`
  (o mesmo id_token vale por 1 h). Conta desativada não entra.
- **Vincular/desvincular**: Configurações → Segurança → "Conta Google" (web)
  e Mais → "Vincular conta Google" (app; `POST`/`DELETE /api/v1/me/google`).
  Desvincular exige senha ou passkey, para a pessoa não ficar sem como entrar.

## Variáveis

| Variável | O que é |
|---|---|
| `GOOGLE_CLIENT_ID` | Client OAuth **Web**. O mesmo do Google Drive (backup) e da Google Agenda. Na VPS: `MINHA_AUTOMACAO_GOOGLE_CLIENT_ID`. Na instalação local: `/opt/minha-automacao/.env` |
| `GOOGLE_CLIENT_SECRET` | Só Drive/Agenda. O login não precisa dele |
| `GOOGLE_LOGIN_AUDIENCES` | Opcional: outros clients aceitos como `aud`, separados por vírgula (ex.: um client iOS no futuro). Na VPS: `MINHA_AUTOMACAO_GOOGLE_LOGIN_AUDIENCES` |

O app não tem variável: o client vem do servidor. Ele não precisa do
`google-services.json` para o login, só para o push.

## Clientes OAuth (Google Cloud, projeto `minha-automacao-114798`)

Use o projeto do Firebase/FCM do app, como nos outros apps da suíte, para que
OAuth, Play e FCM fiquem juntos. Os três clients ficam **no mesmo projeto**: o
Android só emite token para um `serverClientId` do próprio projeto.

1. **Branding / Público-alvo** (tela de consentimento): externo, app
   "Minha Automação", escopos `openid`, `email` e `profile`, domínio
   `minhasuite.com`, links de privacidade e termos (`/privacidade`, `/termos`).
   Publique em produção, porque em "teste" só os testadores entram.
2. **Web** `minha-automacao-web` (tipo "Aplicativo da Web"):
   - Origens JavaScript autorizadas:
     - `https://minhaautomacao.minhasuite.com` (VPS de demonstração)
     - `https://casa-automacao.minhasuite.com` (instalação local do Dell, acesso externo)
     - `http://localhost:3000` (desenvolvimento, opcional)
   - URIs de redirecionamento (Drive/Agenda, não o login):
     `https://minhaautomacao.minhasuite.com/integracoes/oauth/retorno` e
     `https://casa-automacao.minhasuite.com/integracoes/oauth/retorno`.
   - O ID vai em `GOOGLE_CLIENT_ID` e o segredo em `GOOGLE_CLIENT_SECRET`.
3. **Android** `minha-automacao-android-upload`: pacote
   `com.minhasuite.minhaautomacao`, SHA-1 da chave de upload
   `40:96:2F:36:88:CF:E3:54:8D:A8:B8:03:E1:7B:8B:3E:45:03:31:51`. Vale para o
   APK assinado por nós (`./build-apk.sh` com `KEYS_DIR`).
4. **Android** `minha-automacao-android-play`: mesmo pacote, SHA-1 do
   `deployment_cert` da Play App Signing. Tire o SHA-1 com
   `android-suite/scripts/play-signing-cert.sh com.minhasuite.minhaautomacao <conta-de-serviço.json> <versionCode>`,
   não pelo rótulo do Play Console. Sem esse client, o app baixado da loja
   falha com `DEVELOPER_ERROR` (código 10).
5. Se o app Android estiver registrado no Firebase, cadastre lá também os dois
   SHA-1 (upload e Play).

## Instalação local e outras instalações

- **Dell / instalação local**: ponha `GOOGLE_CLIENT_ID` (o client web acima)
  no `.env` e acesse pelo endereço externo `https://casa-automacao.minhasuite.com`.
  Pela rede de casa por IP (`http://192.168.x.x`), o botão da web some, e
  continuam a senha e a passkey. O app entra com Google em qualquer endereço,
  porque o token é nativo e o servidor só confere o `aud`.
- **Outra instalação** (cliente com domínio próprio): use o **mesmo** client
  web e acrescente a origem `https://<domínio>`. O app só funciona com
  client web do projeto `minha-automacao-114798`, porque o client Android
  (pacote + SHA-1) existe uma vez só.
