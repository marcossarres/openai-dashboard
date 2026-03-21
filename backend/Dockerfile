FROM node:22-alpine

WORKDIR /app

# Copy package files and install production deps only
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

# Copy source
COPY src/ ./src/

EXPOSE 3001

CMD ["node", "src/server.js"]
