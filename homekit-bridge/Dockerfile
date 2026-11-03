# Ponte HomeKit do Minha Automação (ondaC1): hap-nodejs em Node, sem nada do Rails.
FROM node:22-bookworm-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY index.js ./
ENV HAP_STORAGE_PATH=/data NODE_ENV=production
CMD ["node", "index.js"]
