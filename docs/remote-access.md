# Acesso remoto gerenciado

Como a casa é vista de fora (app no 4G, avisos com link, Alexa). Nenhuma
porta do roteador fica aberta: o servidor da casa abre um túnel de saída.

## O que existe (base)

- **Registro de provedores** `RemoteAccess::PROVIDERS` (`app/services/remote_access.rb`).
  Provedor = subclasse de `RemoteAccess::Provider` com `describe key:, icon:`,
  `fields` (`[{key, secret}]`, rótulos em `remote.<key>.fields.*` nos três
  idiomas), `enable!(tenant, form)` e `disable!(tenant)`. A tela
  (Configurações → Acesso remoto) desenha um cartão por provedor, sem `case`.
- **Cloudflare Tunnel** (`cloudflare`): a pessoa cria o túnel na Cloudflare
  (Zero Trust → Networks → Tunnels), aponta o hostname para `http://web:3000` e
  cola o token. O token fica cifrado em `tenants.settings["remote_access"]["secret"]`
  (Active Record Encryption) e nunca volta para a tela.
- **Quem roda o túnel** é o supervisor: `POST /system/remote {provider, token}`
  cria o container `minha-automacao-remote` (`cloudflare/cloudflared`, rede
  `<projeto>_default`, reinício automático); `DELETE /system/remote` remove;
  `GET /system/remote` diz o estado.
- **Túnel manual tem prioridade**: se o compose já roda o serviço
  `cloudflared` (perfil `tunnel`, `CF_TUNNEL_TOKEN` no `.env`, como no
  servidor de casa de hoje), a tela mostra "Configurado no servidor" e não
  liga outro. Nada aqui mexe nesse túnel.
- **Plano**: ligar exige `Licensing.allowed?(tenant, "remote_access")`.

## Serviço gerenciado MinhaSuite (desenho, não implementado)

Objetivo: o cliente liga um botão e ganha `nome.minhasuite.com`, sem conta na
Cloudflare.

### Peças

1. **Central (`relay.minhasuite.com`)**, um serviço novo da suíte:
   - cadastro da instalação: o servidor da casa se registra com a licença
     (`Licencas`, mesma conta do cliente) e recebe um **id de instalação** e
     um **segredo de túnel** (rotacionável);
   - escolha do subdomínio (`[a-z0-9-]{3,30}`, único, palavras reservadas
     bloqueadas), um por instalação, com troca limitada (1 por 30 dias);
   - DNS curinga `*.minhasuite.com` apontando para os relays;
   - **relays** (2+ regiões): terminam o TLS (certificado curinga), acham o
     túnel ativo do subdomínio e repassam HTTP/WebSocket (o `/cable`) por ele.
2. **Cliente na casa**: provedor `MinhaSuiteRelay` neste registro. Duas opções
   de transporte, escolher na implementação:
   - (a) a central cria e gerencia um túnel Cloudflare por cliente pela API da
     Cloudflare (conta da MinhaSuite) e devolve o token: o cliente continua
     sendo o `cloudflared` do supervisor, sem código novo de túnel;
   - (b) túnel próprio (WebSocket/HTTP2 de saída, ex. `frp` ou `rathole`)
     num container do supervisor, com o segredo de túnel.
   A opção (a) é a mais rápida de lançar; a (b) tira a dependência de terceiro.
3. **Tela**: o cartão "Acesso MinhaSuite" (já desenhado como "Em breve") vira
   o formulário do provedor: escolher o subdomínio, ver o estado e o tráfego do mês.

### Cobrança

- Incluído nos planos `plus` e `pro` (`Licensing::PLANS[..]["remote_access"]`);
  `free` vê o cartão com o convite para mudar de plano.
- A central confere a licença a cada renovação do segredo (diária); plano
  vencido = túnel derrubado depois de 7 dias de carência, com aviso no app.
- Franquia de tráfego por plano (medida no relay), sem cobrar excedente na
  primeira versão: só aviso.

### Segurança

- O relay nunca vê senha nem sessão em claro fora do TLS dele; logs só com
  subdomínio, status e bytes.
- Rate limit por subdomínio no relay; bloqueio manual pela central.
- O servidor da casa continua exigindo login; o relay não autentica por ele.
