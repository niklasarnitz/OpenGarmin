# Build from the repository root (the server depends on ../GarminKit, and the dashboard is built from ../Web):
#   docker build -f Server/Dockerfile -t opengarmin-server .

# The dashboard: a static single-page app, built into dist/ and served from the server's Public/ directory.
FROM oven/bun:1 AS web
WORKDIR /web
COPY Web/package.json Web/bun.lock ./
RUN bun install --frozen-lockfile
COPY Web ./
RUN bun run build

FROM swift:6.2-noble AS build
WORKDIR /src
COPY GarminKit /src/GarminKit
COPY Server /src/Server
WORKDIR /src/Server
RUN swift build -c release --static-swift-stdlib --product App \
 && cp "$(swift build -c release --show-bin-path)/App" /src/app

FROM swift:6.2-noble-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /app --shell /usr/sbin/nologin opengarmin \
 && mkdir -p /data && chown opengarmin:opengarmin /data
WORKDIR /app
COPY --from=build /src/app /app/App
COPY --from=build /src/Server/Public /app/Public
# The dashboard replaces the placeholder index.html; connect.html stays.
COPY --from=web /web/dist /app/Public
ENV PORT=8080 OPENGARMIN_DATA_DIR=/data
USER opengarmin
EXPOSE 8080
VOLUME ["/data"]
ENTRYPOINT ["/app/App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
