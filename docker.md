Running Millipede in Docker with Let's Encrypt
==============================================

Target setup: a headless Ubuntu VPS running the caster in a container, with
configuration and certificates living on the host so they survive image
rebuilds, and certificates issued and renewed automatically by Let's Encrypt.

Contents:

1. [How the caster finds its files](#1-how-the-caster-finds-its-files)
2. [Host directory layout](#2-host-directory-layout)
3. [Dockerfile](#3-dockerfile)
4. [Configuration](#4-configuration)
5. [docker-compose.yml](#5-docker-composeyml)
6. [Let's Encrypt](#6-lets-encrypt)
7. [Reload on renewal](#7-reload-on-renewal)
8. [Bootstrapping the first certificate](#8-bootstrapping-the-first-certificate)
9. [Logs](#9-logs)
10. [Operating notes](#10-operating-notes)


1. How the caster finds its files
---------------------------------

This drives the whole layout, so it is worth stating first.

The caster takes its configuration file with `-c`, and derives a **config
directory** from it — the directory containing that file (`caster.c`,
`caster_new()`). Every other path in `caster.yaml` is resolved through
`joinpath()`: **relative paths are relative to the config directory, absolute
paths are used as-is.**

That applies to `sourcetable_file`, `source_auth_file`, `host_auth_file`,
`blocklist_file`, `tls_full_certificate_chain`, `tls_private_key`, the
`webroots` paths, and the log files.

So if the container runs `caster -c /etc/millipede/caster.yaml`, everything
referenced relatively resolves under `/etc/millipede/`. Mount one host
directory there and the whole configuration is persistent.

Command line (`main.c`):

    caster [-c config file] [-d] [-t nthreads]

Use `-c` and `-t`. Do **not** use `-d` (daemonize) in a container — the
container must keep the caster in the foreground as PID 1.


2. Host directory layout
------------------------

    /srv/millipede/
    ├── config/                 -> /etc/millipede in the container (read-only)
    │   ├── caster.yaml
    │   ├── sourcetable.dat
    │   ├── source.auth
    │   ├── host.auth
    │   ├── blocklist
    │   └── certs/              certificates copied here by the renewal hook
    │       ├── fullchain.pem
    │       └── privkey.pem
    ├── acme/                   -> /srv/acme in the container (read-only)
    │   └── .well-known/acme-challenge/     certbot writes challenges here
    └── log/                    -> /var/log/millipede (read-write)
        ├── caster.log
        └── access.log

Create it and give it to the UID the container runs as (1000 below):

    sudo mkdir -p /srv/millipede/{config/certs,acme,log}
    sudo chown -R 1000:1000 /srv/millipede

The caster only ever *reads* its configuration, so `config/` and `acme/` can be
mounted read-only. Only the log directory needs to be writable.


3. Dockerfile
-------------

Build with the provided `caster/Makefile`. Two stages, so the runtime image
carries no compiler or headers.

Base the image on **Debian bookworm**, not Ubuntu 22.04: the caster requires
json-c >= 0.16 and Ubuntu 22.04 ships 0.15. The host being Ubuntu makes no
difference — only the base image matters.

This is the committed `Dockerfile`; a `.dockerignore` next to it keeps `.git`
and any host build artifacts out of the build context:

```dockerfile
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

# Exec form: the caster must be PID 1 so it receives SIGHUP and SIGTERM.
ENTRYPOINT ["/usr/local/sbin/caster"]
CMD ["-c", "/etc/millipede/caster.yaml", "-t", "4"]
```

`ca-certificates` is required if you use TLS as a *client* — the proxy,
`node` or `graylog` sections. The client context calls
`SSL_CTX_set_default_verify_paths()` and verifies the peer hostname, so
without the system CA bundle those outgoing connections fail.

The runtime package names are the ones current in bookworm. Verify the
binary resolves everything after building:

    docker run --rm --entrypoint ldd millipede /usr/local/sbin/caster | grep -i "not found"

No output means you are good. If a package name has moved, find it with
`apt-cache search libevent` in the build stage.


4. Configuration
----------------

`/srv/millipede/config/caster.yaml`, adapted from `sample-config/caster.yaml`:

```yaml
listen:
  # NTRIP, plaintext
  - port:                       2101
    ip:                         ::0

  # NTRIP over TLS
  - port:                       2443
    ip:                         ::0
    tls:                        true
    tls_full_certificate_chain: certs/fullchain.pem
    tls_private_key:            certs/privkey.pem
    hostname:                   caster.example.org

  # HTTP, for the ACME challenge only. Published as port 80 by Docker.
  - port:                       8080
    ip:                         ::0

# Serves the Let's Encrypt HTTP-01 challenge, on every listener, without
# authentication. The request URI is appended to path, so a request for
# /.well-known/acme-challenge/TOKEN is read from
# /srv/acme/.well-known/acme-challenge/TOKEN
webroots:
  - uri:                        /.well-known/acme-challenge/
    path:                       /srv/acme

source_auth_file:               source.auth
host_auth_file:                 host.auth
sourcetable_file:               sourcetable.dat
blocklist_file:                 blocklist

access_log:                     /var/log/millipede/access.log
log:                            /var/log/millipede/caster.log
log_level:                      INFO

admin_user:                     admin
```

Two things to note:

* **Ports are high inside the container.** The caster runs as an unprivileged
  user and cannot bind ports below 1024. Docker publishes host 80 to container
  8080, so no `CAP_NET_BIND_SERVICE` is needed. 2101 and 2443 are above 1024
  and are published unchanged.
* **`hostname:` is a check, not a selector.** When set, the SNI callback
  refuses handshakes whose SNI does not match it (`SSL_TLSEXT_ERR_NOACK`).
  It does not select between several certificates — one certificate per
  listener. Leave it out if clients may connect by IP address.

`log_level: DEBUG` and `EDEBUG` write passwords to the log. Keep `INFO` in
production.


5. docker-compose.yml
---------------------

`Dockerfile`, `docker-compose.yml` and `.dockerignore` are in the repository
root, so this is the file as committed:

```yaml
services:
  caster:
    build: .
    image: millipede:latest
    container_name: millipede
    restart: unless-stopped
    user: "1000:1000"
    command: ["-c", "/etc/millipede/caster.yaml", "-t", "4"]
    ports:
      - "2101:2101"     # NTRIP
      - "2443:2443"     # NTRIP over TLS
      - "80:8080"       # ACME HTTP-01 challenge
    volumes:
      - /srv/millipede/config:/etc/millipede:ro
      - /srv/millipede/acme:/srv/acme:ro
      - /srv/millipede/log:/var/log/millipede
```

Run it from the source checkout — the build context is the repository itself,
while the persistent state stays outside it under `/srv/millipede`:

    git clone <this repository> /opt/millipede-caster
    cd /opt/millipede-caster
    docker compose up -d --build

`-t` is the number of threads (`main.c` usage text): any value above 1 enables
multithreaded mode, `-t 1` or omitting it runs single-threaded. Internally the
caster derives one libevent event base per 4 threads. Set it to roughly the
VPS core count.


6. Let's Encrypt
----------------

Run **certbot on the host**, not in a container. On a single VPS this is the
arrangement with the fewest moving parts: no second container competing for
port 80, no Docker socket handed to certbot, and renewal is driven by the
systemd timer certbot already installs.

    sudo apt install certbot

Issue the certificate in `--webroot` mode, pointing at the directory the
caster serves:

    sudo certbot certonly \
        --webroot -w /srv/millipede/acme \
        -d caster.example.org \
        --email you@example.org --agree-tos --no-eff-email

Certbot writes the token to
`/srv/millipede/acme/.well-known/acme-challenge/<TOKEN>`, Let's Encrypt
fetches `http://caster.example.org/.well-known/acme-challenge/<TOKEN>` on port
80, Docker forwards it to the caster's port 8080, and `filesrv()` serves it
straight from the mounted directory. The caster keeps running throughout —
no downtime, no port juggling.

### Why the certificates are copied rather than mounted

It is tempting to bind-mount `/etc/letsencrypt/live/<domain>` into the
container. Two things break:

* `/etc/letsencrypt/live/<domain>/*.pem` are **symlinks** into
  `/etc/letsencrypt/archive/<domain>/`. Mounting only `live/` gives the
  container dangling links. You would have to mount `archive/` as well.
* `privkey.pem` is `root:root 0600`. The container runs as UID 1000 and
  cannot read it.

So the deploy hook copies both files into the config directory with
ownership and permissions the caster can use. That also keeps the container
away from your entire ACME account state.


7. Reload on renewal
--------------------

The caster reloads its configuration on **SIGHUP** (`signalhup_cb` →
`caster_reload`), which rebuilds each listener's TLS context from the
certificate files on disk. Existing connections are unaffected: a reload
builds a new `SSL_CTX` and swaps it in, and handshakes already in progress
keep the context they started with.

Create `/etc/letsencrypt/renewal-hooks/deploy/millipede.sh`:

```sh
#!/bin/sh
set -e

DOMAIN=caster.example.org
DEST=/srv/millipede/config/certs

# Only act on our own certificate; the hook runs for every renewed lineage.
[ "$RENEWED_LINEAGE" = "/etc/letsencrypt/live/$DOMAIN" ] || exit 0

install -o 1000 -g 1000 -m 0644 "$RENEWED_LINEAGE/fullchain.pem" "$DEST/fullchain.pem"
install -o 1000 -g 1000 -m 0640 "$RENEWED_LINEAGE/privkey.pem"   "$DEST/privkey.pem"

docker kill -s HUP millipede
```

    sudo chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/millipede.sh

`install` follows the symlinks and copies the actual contents, so the
container never sees a dangling link.

**The order matters.** If the caster reloads while the certificate and the
private key on disk do not match — or one of them is unreadable — TLS setup
fails for that listener and the reload drops the port entirely, until the
next successful reload. Copying both files first and signalling last, with
`set -e` aborting on a failed copy, avoids reloading onto a half-written
pair.

Check that renewal works end to end without waiting 60 days:

    sudo certbot renew --dry-run

Note that `--dry-run` exercises the challenge but does **not** run deploy
hooks. To test the hook itself, run the script by hand with
`RENEWED_LINEAGE=/etc/letsencrypt/live/caster.example.org`.

### Alternative: reload through the API

If you would rather not give the hook access to the Docker CLI, the caster
also reloads on `POST /adm/api/v1/reload`, authenticated as `admin_user`
against `source.auth`:

    curl -u admin:PASSWORD -X POST http://127.0.0.1:2101/adm/api/v1/reload

The bundled `mapi reload` tool does the same. Do not expose `/adm` to the
internet.


8. Bootstrapping the first certificate
--------------------------------------

Chicken-and-egg: the config references certificate files that do not exist
until certbot has run, but certbot needs the caster up to answer the
challenge. This resolves itself — no special-casing needed.

Listener setup is per-listener: a listener whose certificate cannot be loaded
is logged as `Unable to open listener` and skipped, and the caster carries on
with the rest. It only aborts if *no* listener at all could be opened.

So the sequence is simply:

1. `docker compose up -d` with the TLS listener already in `caster.yaml`.
   Ports 2101 and 8080 come up; 2443 fails and is logged.
2. Point the DNS A/AAAA record for `caster.example.org` at the VPS.
3. Run the `certbot certonly` command from section 6.
4. Copy the certificates in and reload — the same two steps the deploy hook
   does later:

       sudo /etc/letsencrypt/renewal-hooks/deploy/millipede.sh

   (with `RENEWED_LINEAGE` set, or just run the `install` and `docker kill`
   commands by hand the first time).
5. Confirm 2443 is now listening:

       docker logs millipede | grep -i listener
       openssl s_client -connect caster.example.org:2443 -servername caster.example.org </dev/null


9. Logs
-------

The caster writes to the files given by `log:` and `access_log:`. With the
layout above they land in `/srv/millipede/log/` on the host, which is the
simplest arrangement: they persist, and you can rotate them with logrotate.
SIGHUP reopens the log files as well as reloading the configuration, so a
logrotate `postrotate` running `docker kill -s HUP millipede` is all that is
needed.

If you would rather have `docker logs` show everything, set:

```yaml
log:            /dev/stdout
access_log:     /dev/stdout
```

This works because the caster opens the paths with `fopen(..., "a")` and
line-buffers them. It requires the container to *not* be started with `-d`
(it is not, above). If you hit a permission error opening `/dev/stdout` as a
non-root user, fall back to files.


10. Operating notes
-------------------

**Docker bypasses UFW.** Published ports are inserted into iptables' DOCKER
chain, which is evaluated before UFW's rules — `ufw deny 2101` will not stop
traffic to a published container port. If you need to restrict access, bind
the publication to an address (`"127.0.0.1:2101:2101"`) or filter in
`DOCKER-USER`.

**Signals.** The caster handles SIGHUP (reload), and SIGINT/SIGTERM (clean
shutdown), so `docker stop` and `docker compose restart` behave properly —
provided the caster is PID 1, which the exec-form `ENTRYPOINT` guarantees.
Do not wrap it in a shell script.

**Image rebuilds.** Nothing in the image is stateful. `docker compose build
--pull && docker compose up -d` replaces the binary; configuration,
certificates and logs are all on the host.

**What actually needs to persist:** `/srv/millipede/config` (configuration,
sourcetable, credentials, certificates), `/srv/millipede/log` if you want log
history, and `/etc/letsencrypt` (ACME account and certificate lineages —
back this up). `/srv/millipede/acme` holds only transient challenge tokens.

**Time.** RTK and TLS both care about the clock. Make sure `systemd-timesyncd`
or `chrony` is running on the host; the container inherits the host clock.
