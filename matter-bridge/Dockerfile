# Ponte Matter do Minha Automação (integ): matter.js em Node, sem nada do Rails.
FROM node:22-bookworm-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY index.js ./
ENV MATTER_STORAGE_PATH=/data NODE_ENV=production
CMD ["node", "index.js"]
