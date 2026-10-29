FROM ruby:3.3.10-slim

# Deps do sistema (libvips para reduzir foto antes da IA — Ai::ImageDownscaler).
# Cliente do Postgres 18 (PGDG), igual ao servidor: o pg_dump do Debian (17)
# recusa servidor mais novo e o db/structure.sql sai dele.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
  build-essential \
  libpq-dev \
  libyaml-dev \
  git \
  curl \
  ca-certificates \
  libvips42 \
  fonts-dejavu-core \
  && install -d /usr/share/postgresql-common/pgdg \
  && curl -fsSo /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
  && apt-get update -qq && apt-get install -y --no-install-recommends postgresql-client-18 \
  && rm -rf /var/lib/apt/lists/*

RUN gem install bundler -v 2.5.22

WORKDIR /app
