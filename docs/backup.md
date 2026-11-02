# Backup fora de casa (G20)

O servidor da casa já faz um `pg_dump` por dia (serviço `backup` do
`docker-compose.local.yml`, 7 dias em `/opt/minha-automacao/backups`). Se o
disco ou o servidor morrer, essa cópia morre junto. A cópia fora de casa
resolve isso:

1. de hora em hora o worker (`BackupOffsiteJob`) olha o dump mais novo da
   pasta; se ainda não foi mandado, **cifra** e manda para o destino;
2. guarda só as `BACKUP_OFFSITE_KEEP` cópias mais novas no destino;
3. todo domingo às 5h baixa a cópia mais nova do destino, restaura num banco
   temporário (`ma_restore_*`, apagado no fim) e confere as contagens de
   `tenants`, `users`, `sites`, `devices`, `points`, `automations` e
   `dashboards` com o banco vivo (tolerância de 5 linhas ou 10%: o banco anda
   desde o dump).

O resultado aparece em **Configurações → Saúde → Backup** (cópia diária,
cópia fora de casa e teste de restauração), vira aviso para os
administradores quando falha e vira o ponto "Backup externo atrasado ou com
falha" da integração Sistema (para alertas e automações). O estado fica em
`storage/backup-offsite.json` (volume `storage`).

## Variáveis (no `.env` do servidor; nunca no repo)

| Variável | Para quê |
|---|---|
| `BACKUP_OFFSITE_URL` | Destino. `ssh://usuario@host:porta/pasta` (VPS) ou `s3://bucket/prefixo` (R2, B2, MinIO, AWS) |
| `BACKUP_PASSPHRASE` | Senha da cifra (longa, aleatória). **Guarde fora do servidor** (gerenciador de senhas): sem ela a cópia não abre |
| `BACKUP_OFFSITE_KEEP` | Quantas cópias ficam no destino (padrão 14) |
| `BACKUP_SSH_KEY_FILE` | SSH: chave privada (padrão `/secrets/backup_ssh_key`; a pasta `./secrets` do servidor entra só-leitura) |
| `BACKUP_SSH_KNOWN_HOSTS` | SSH: onde guardar a chave do host (padrão `storage/backup_known_hosts`; gravada na 1ª conexão) |
| `BACKUP_S3_ENDPOINT` | S3: endereço (R2: `https://<conta>.r2.cloudflarestorage.com`; B2: `https://s3.<região>.backblazeb2.com`) |
| `BACKUP_S3_ACCESS_KEY_ID` / `BACKUP_S3_SECRET_ACCESS_KEY` | S3: chave com acesso só ao bucket |
| `BACKUP_S3_REGION` | S3: região (padrão `auto`, o do R2) |
| `BACKUP_DIR` | Pasta dos dumps (padrão `/backups`) |

Sem `BACKUP_OFFSITE_URL` **e** `BACKUP_PASSPHRASE` a cópia fica desligada e a
tela de saúde mostra "Não configurada".

## Ligar (coordenador)

### Destino na VPS por SSH

```bash
# no Dell, em /opt/minha-automacao
mkdir -p secrets && ssh-keygen -t ed25519 -N '' -C ma-backup -f secrets/backup_ssh_key
chmod 700 secrets && chmod 600 secrets/backup_ssh_key
# o container roda como root: ele lê a chave mesmo com 600

# na VPS: usuário só para backup, pasta própria, chave restrita
sudo adduser --disabled-password --gecos '' mabackup
sudo -u mabackup mkdir -p ~mabackup/.ssh /srv/ma-backups && sudo chown mabackup /srv/ma-backups
# cole secrets/backup_ssh_key.pub em ~mabackup/.ssh/authorized_keys com:
#   restrict,from="<IP público da casa>" ssh-ed25519 AAAA... ma-backup
```

`.env`:

```
BACKUP_OFFSITE_URL=ssh://mabackup@<vps>:22/srv/ma-backups
BACKUP_PASSPHRASE=<openssl rand -base64 48>
```

O destino usa `ssh`/`scp` (o `openssh-client` vem na imagem): `mkdir -p`,
envio como `.tmp` + `mv` (nunca fica arquivo pela metade), `ls -1` e `rm -f`.

### Destino S3 (R2/B2)

Crie um bucket só para isso e uma chave com acesso só a ele. `.env`:

```
BACKUP_OFFSITE_URL=s3://ma-backups/casa
BACKUP_S3_ENDPOINT=https://<conta>.r2.cloudflarestorage.com
BACKUP_S3_ACCESS_KEY_ID=...
BACKUP_S3_SECRET_ACCESS_KEY=...
BACKUP_PASSPHRASE=...
```

Depois: `bin/deploy-local` (sobe com o `.env` novo) e, para não esperar a
hora cheia, rode na hora:

```bash
docker compose exec worker bin/rails runner 'Backups.offsite!(force: true); puts Backups.status'
docker compose exec worker bin/rails runner 'Backups.restore_test!; puts Backups.status'
```

## Restaurar de verdade (sem o app)

A cópia é o formato do `openssl enc`, então abre em qualquer máquina com
OpenSSL 1.1.1+:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 \
  -in minha_automacao-AAAA-MM-DD.sql.gz.enc -pass env:BACKUP_PASSPHRASE \
  | gunzip > dump.sql
# servidor novo: suba só o db do compose e restaure num banco vazio
docker compose up -d db
docker compose exec -T db psql -U minha_automacao -d minha_automacao < dump.sql
docker compose up -d
```

Antes de restaurar por cima de um banco que existe, renomeie o antigo (não
apague) até conferir. O `.env` (segredos, `AR_ENCRYPTION_*`) não vai na
cópia: guarde-o à parte; sem as chaves `AR_ENCRYPTION_*` as credenciais
cifradas das integrações não abrem (refaça o login delas).

## Destino novo

Classe em `app/services/backups/destinations.rb` (ou arquivo próprio) com
`self.owns?(uri)`, `self.label` e, por instância criada com a URI,
`upload(caminho, nome)`, `list`, `delete(nome)`, `download(nome, caminho)` e
`describe` (sem segredo) + o nome em `Backups::DESTINATIONS`. O spec
`spec/services/corte_health_backup_spec.rb` registra um destino falso (pasta
local) por `stub_const` e mostra o contrato.

## Riscos conhecidos

- O `psql` da imagem (Debian) é mais velho que o servidor 18; o teste de
  restauração tira as linhas `\restrict`/`\unrestrict` do dump (meta-comandos
  de segurança do `pg_dump` novo, que o `psql` velho não entende). O resto do
  SQL roda no servidor 18.
- A cifra é AES-256-CBC (compatibilidade com o `openssl enc`), sem
  autenticação própria: um arquivo adulterado falha na abertura ou no
  `gunzip`, e o teste de restauração semanal é a prova de que a cópia abre.
