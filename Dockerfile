# Millipede NTRIP caster.
#
# See docker.md for the full setup, including persistent configuration
# and Let's Encrypt certificates.
#
# Debian bookworm is used rather than Ubuntu 22.04, which ships json-c 0.15
# while the caster requires >= 0.16.

# ---- build stage ----
FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libcyaml-dev \
        libevent-dev \
        libjson-c-dev \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
RUN cd caster && make clean all

# ---- runtime stage ----
FROM debian:bookworm-slim

# ca-certificates is needed for outgoing TLS connections (proxy, node and
# graylog sections): the client context verifies peers against the system
# CA store.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libcyaml1 \
        libevent-core-2.1-7 \
        libevent-extra-2.1-7 \
        libevent-openssl-2.1-7 \
        libevent-pthreads-2.1-7 \
        libjson-c5 \
        libssl3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/caster/caster /usr/local/sbin/caster
COPY --from=build /src/caster/bin/mapi /usr/local/sbin/mapi

RUN useradd --system --uid 1000 --no-create-home --shell /usr/sbin/nologin caster
USER caster

# Exec form: the caster must be PID 1 to receive SIGHUP (reload) and
# SIGTERM (clean shutdown). Do not wrap it in a shell script.
ENTRYPOINT ["/usr/local/sbin/caster"]
CMD ["-c", "/etc/millipede/caster.yaml", "-t", "4"]
