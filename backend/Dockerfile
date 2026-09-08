FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
ENV ASTRA_SESSION_HOST=0.0.0.0
ENV ASTRA_ILLUSTRATION_DIR=/app/.local/illustrations
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
RUN mkdir -p /app/.local/illustrations && chown -R node:node /app/.local
USER node
EXPOSE 8787
CMD ["node", "dist/index.js"]
