FROM --platform=$BUILDPLATFORM 84codes/crystal:latest-alpine AS object-builder
WORKDIR /tmp
COPY shard.yml shard.lock .
RUN shards install --production
COPY src src
ARG TARGETARCH
RUN crystal build src/amqpshovel.cr --release --no-debug --static --cross-compile --target $TARGETARCH-alpine-linux-musl > amqpshovel.sh

FROM 84codes/crystal:latest-alpine AS builder
WORKDIR /tmp
COPY --from=object-builder /tmp/amqpshovel.* .
RUN sh -ex amqpshovel.sh && strip amqpshovel

FROM scratch AS export-stage
COPY --from=builder /tmp/amqpshovel .

FROM scratch
COPY --from=builder /etc/ssl3/cert.pem /etc/ssl3/
COPY --from=builder /tmp/amqpshovel /usr/bin/
USER 65534:65534
ENTRYPOINT ["/usr/bin/amqpshovel"]
