# Ambiente de desenvolvimento

Ruby só em container (podman rootless como `docker`). Portas próprias:
Postgres `127.0.0.1:6299`, app `:4121`.

```bash
cd ~/projects/minha-automacao-workspace/minha-automacao
docker compose -f .devcontainer/docker-compose.yml up -d
R() { docker compose -f .devcontainer/docker-compose.yml exec -T app bash -c "cd /app && $*"; }

R 'bundle install && bin/rails db:prepare'          # banco + seeds (IA, teste@teste.com)
R 'bin/rails tailwindcss:build'                       # CSS (layout e specs que renderizam HTML)
R 'bin/rails server -b 0.0.0.0 -p 4121'              # http://localhost:4121
R 'bundle exec rspec && bundle exec rubocop --parallel && bundle exec brakeman -q'
```

- Use `bash -c` (não `bash -lc`): o login shell perde `/usr/local/bundle/bin`.
- Não rode `chown` dentro do container; se o dono dos arquivos mudar:
  `podman unshare chown -R 0:0 .`.
- Em dev os jobs rodam em `:async` (sem worker). Para a fila de verdade:
  `R 'bin/jobs'`.
- Credenciais opcionais (`.env.example`): sem elas IA, Google, FCM e
  licenças ficam desligados — o resto funciona.
- Login de teste: `teste@teste.com` / `12345678` (só em dev).
