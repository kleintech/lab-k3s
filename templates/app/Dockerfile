# syntax=docker/dockerfile:1
#
# Multi-stage example for a Node.js web service. Replace with whatever the project needs;
# the pattern to keep: build in a fat image, ship only the runtime artifacts in a slim one,
# run as a non-root user, listen on $PORT (8080 here, matching k8s/deployment.yaml).
#
# Build and push by hand (dev loop):
#   docker build -t registry.lab.kleincogroup.com/<project>/<name>:dev .
#   docker push registry.lab.kleincogroup.com/<project>/<name>:dev
# CI does the same with the git SHA as the tag (.github/workflows/ci.yaml).

ARG NODE_VERSION=22

# ---- deps: install all dependencies once, cached on package*.json --------------------
FROM node:${NODE_VERSION}-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

# ---- build: compile/bundle (TypeScript, a frontend bundle, ...) ---------------------
FROM deps AS build
COPY . .
# Assumes a "build" script that writes to dist/. Drop this stage if there is no build step.
RUN npm run build
# Strip devDependencies so the runtime stage copies production deps only.
RUN npm prune --omit=dev

# ---- runtime: only what is needed to run --------------------------------------------
FROM node:${NODE_VERSION}-slim AS runtime
ENV NODE_ENV=production \
    PORT=8080
WORKDIR /app
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=build --chown=node:node /app/package.json ./
# The official node image ships an unprivileged "node" user. Use its numeric uid: the
# Deployment sets runAsNonRoot, and the kubelet refuses a non-numeric USER under it.
USER 1000:1000
EXPOSE 8080
CMD ["node", "dist/server.js"]
