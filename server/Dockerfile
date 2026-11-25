FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 go build -o /out/directd ./cmd/directd \
    && CGO_ENABLED=0 go build -o /out/direct-admin ./cmd/direct-admin && mkdir /out/data

# instalador (deploy/docker-compose.yml, serviço setup); o script vem de deploy/ montado em /deploy
FROM postgres:17 AS setup
RUN apt-get update && apt-get install -y --no-install-recommends e2fsprogs && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/directd /out/direct-admin /usr/local/bin/
ENTRYPOINT ["bash", "/deploy/setup.sh"]

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/directd /directd
COPY --from=build /out/direct-admin /direct-admin
COPY --from=build --chown=nonroot:nonroot /out/data /data
# registro de comandos da CLI: no volume, fora do banco
ENV DIRECT_ADMIN_LOG=/data/admin.log
USER nonroot:nonroot
ENTRYPOINT ["/directd"]
