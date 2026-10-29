FROM ruby:3.3.10-slim

# Deps do sistema (libvips para reduzir foto antes da IA — Ai::ImageDownscaler)
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
  build-essential \
  libpq-dev \
  libyaml-dev \
  git \
  curl \
  libvips42 \
  fonts-dejavu-core \
  postgresql-client \
  && rm -rf /var/lib/apt/lists/*

RUN gem install bundler -v 2.5.22

WORKDIR /app
