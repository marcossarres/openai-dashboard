# ── Stage 1: build ──────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install

COPY . .
RUN npm run build

# ── Stage 2: serve ──────────────────────────────────────────────────────────
FROM nginx:alpine

# Copy built assets
COPY --from=builder /app/dist /usr/share/nginx/html

# Copy nginx template — BACKEND_HOST and BACKEND_PORT are injected at runtime
COPY nginx.conf /etc/nginx/templates/default.conf.template

# Default values (override via ECS task env vars)
ENV BACKEND_HOST=backend
ENV BACKEND_PORT=3001

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
