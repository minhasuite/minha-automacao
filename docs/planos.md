# Planos do produto (licença)

Não confundir com a assinatura da IA (`Plans`, `Billing`, cobrada pela Play):
esta é a licença de uso do Minha Automação vendido.

## Modelo

- `Licensing::PLANS`: `free`, `plus`, `pro`, cada um com os limites
  (`nil` = sem limite; `true`/`false` = recurso ligado ou não):

  | limite          | free | plus | pro |
  |-----------------|------|------|-----|
  | `devices`       | 25   | 150  | —   |
  | `users`         | 3    | 10   | —   |
  | `history_days`  | 30   | 365  | —   |
  | `cloud_backup`  | não  | sim  | sim |
  | `remote_access` | não  | sim  | sim |

- **Tipos de limite são um registro** (`Licensing::LIMITS`): classe com
  `describe key:, kind:` (`:count`, `:days`, `:flag`) e `usage(tenant)`.
  Limite novo = classe + nome em `LIMITS` + rótulo `plan.limits.<key>` nos
  três idiomas + valor em cada plano.
- **Por instalação**: `tenants.settings["license"] = {"plan", "limits"}`;
  `limits` sobrepõe o do plano (cortesia, contrato especial).
  `Licensing.set!(tenant, "plus", limits: {"devices" => 300})`.
- **Sem licença gravada** vale `LICENSE_DEFAULT_PLAN` (padrão `pro`): quem já
  usa (o servidor de casa do dono) continua ilimitado.

## Checagem central

- `Licensing.allowed?(tenant, key, adding: 1)` e `Licensing.check!` (levanta
  `Licensing::Exceeded` com o texto pronto `Licensing.message(key)`).
- Já ligados: criar aparelho (`Device` valida no create; helpers e scripts não
  contam), criar pessoa (`User`), ligar o acesso remoto (`RemoteAccess.enable!`).
- A ligar quando as peças existirem: `cloud_backup` no destino de backup em
  nuvem (`Licensing.allowed?(tenant, "cloud_backup")` antes de enviar) e
  `history_days` na retenção do `ReadingsMaintenanceJob` (menor entre o do
  ponto e o do plano).

## Pagamento (interface, ainda vazio)

`Licensing::PAYMENT_PROVIDERS = []`. Provedor de pagamento novo (Stripe,
Mercado Pago, Play, central de licenças) = módulo com:

- `key`, `label` (texto `payment.<key>.label`);
- `checkout_url(tenant, plan, return_url:)` → endereço para pagar;
- `webhook(request)` → `{tenant_id, plan, status, expires_at}` validado pela
  assinatura do provedor;
- `cancel!(tenant)`.

O webhook chama `Licensing.set!` com o plano pago; vencido = volta para o
`free` (os dados ficam; o que passa do limite fica só leitura: nada é apagado).
A tela Configurações → Plano mostra o botão de cada provedor quando a lista não
estiver vazia.
