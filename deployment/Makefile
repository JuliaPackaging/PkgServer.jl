# Default target is to bring everything up
all: up

# Use docker compose if it exist, fall back to docker-compose
COMPOSE=$(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; else echo "docker-compose"; fi)

# Extract configuration from `.env` file
PKG_SERVER_REGION := $(shell bash -c "source .env 2>/dev/null && echo \$$PKG_SERVER_REGION")
ifeq ($(PKG_SERVER_REGION),)
$(error "Must specify PKG_SERVER_REGION in .env!")
endif

PKG_SERVER_FQDN := $(shell bash -c "source .env 2>/dev/null && echo \$$PKG_SERVER_FQDN")
ifeq ($(PKG_SERVER_FQDN),)
# Default the FQDN to `region.pkg.julialang.org`
PKG_SERVER_FQDN := $(PKG_SERVER_REGION).pkg.julialang.org
endif
export PKG_SERVER_FQDN
S3_MIRROR_BUCKET_LIST := $(shell bash -c "source .env 2>/dev/null && echo \$$S3_MIRROR_BUCKET_LIST")
DISABLE_TLS := $(shell bash -c "source .env 2>/dev/null && echo \$$DISABLE_TLS")
DISABLE_INTERNAL_DNS := $(shell bash -c "source .env 2>/dev/null && echo \$$DISABLE_INTERNAL_DNS")
DISABLE_INTERNAL_DNS_IPV6 := $(shell bash -c "source .env 2>/dev/null && echo \$$DISABLE_INTERNAL_DNS_IPV6")

# If `DISABLE_TLS` is defined, use the `http` stanza instead of the `tls` one.
LISTEN_SRC := $(if $(DISABLE_TLS),conf/stanza_http.conf,conf/stanza_tls.conf)
MIRROR_SRC := conf/s3mirror.nginx.conf


SERVERNAMES := $(PKG_SERVER_FQDN)
# Allow the user to disable automatic certificate fetching for internal DNS names
# This is important for the loadbalancer, but not for a naked PkgServer.
ifneq ($(DISABLE_INTERNAL_DNS),1)
SERVERNAMES += pkgserver-$(PKG_SERVER_REGION).ip.cflo.at
SERVERNAMES += pkgserver-$(PKG_SERVER_REGION).ipv4.cflo.at
ifneq ($(DISABLE_INTERNAL_DNS_IPV6),1)
SERVERNAMES += pkgserver-$(PKG_SERVER_REGION).ipv6.cflo.at
endif
endif

# We want to launch/build docker containers as our own UID, so we collect that from the environment
UID:=$(shell id -u)
USER:=$(shell id -u -n)
GID:=$(shell id -g)
GROUP:=$(shell id -g -n)
export UID USER GID GROUP

DIRS := storage/cache storage/s3cache storage/static storage/temp
DIRS += logs/nginx logs/pkgserver build
$(DIRS):
	mkdir -p $@

# Make sure nginx log files are created before starting nginx. Without this the
# nginx master process (running as root) creates them with root as owner.
NGINX_CURRENT_LOGFILES := logs/nginx/access_${PKG_SERVER_FQDN}.log logs/nginx/error_${PKG_SERVER_FQDN}.log
$(NGINX_CURRENT_LOGFILES): logs/nginx
	touch $@
	chmod 0644 $@

# Make sure files have the expected permissions: the nginx master process runs
# as root and sometimes files created by this process trips up the package
# server (which runs as a regular user).
filepermissions: $(DIRS) $(NGINX_CURRENT_LOGFILES)
	sudo chown -R $(UID):$(GID) logs storage
.PHONY: filepermissions
up: filepermissions

# If our pkgserver is given a FQDN, then we splice in the TLS stanza, otherwise the HTTP stanza
build/pkgserver.nginx.conf: conf/pkgserver.nginx.conf ${LISTEN_SRC} | build
	@export FQDN="$(PKG_SERVER_FQDN)"; \
	export SERVERNAMES="$(SERVERNAMES)"; \
	export LISTEN_BLOCK_SRC=$(LISTEN_SRC); \
	export LISTEN_BLOCK="$$(envsubst '$${SERVERNAMES} $${FQDN}' < "$(LISTEN_SRC)")"; \
	MIRROR_BLOCK=""; \
	if [ -n "$(S3_MIRROR_BUCKET_LIST)" ]; then \
		for S3_BUCKET in $(S3_MIRROR_BUCKET_LIST); do \
			export S3_BUCKET; \
			export MIRROR_BLOCK="$${MIRROR_BLOCK} $$(envsubst '$${S3_BUCKET}' < "$(MIRROR_SRC)")"; \
		done; \
	fi; \
	envsubst '$${LISTEN_BLOCK_SRC} $${LISTEN_BLOCK} $${MIRROR_BLOCK} $${REGION} $${FQDN}' < $< > $@

up: $(DIRS) build/pkgserver.nginx.conf
	${COMPOSE} up --build --remove-orphans -d

down:
	${COMPOSE} down --remove-orphans

pull:
	${COMPOSE} pull

# Rule to install logrotate configuration so that host-wide logrotate can
# perform the logrotations, as well as run `make nginx-send-usr1`.
/etc/logrotate.d/pkgserver: conf/logrotate.conf
	LOGDIR=$(shell pwd)/logs SOURCEDIR=$(shell pwd) \
	envsubst '$${LOGDIR} $${SOURCEDIR} $${UID} $${USER} $${GID} $${GROUP}' < $< | sudo tee $@ >/dev/null
up: /etc/logrotate.d/pkgserver

include logrotate.make

# Rule to send nginx USR1 signal via docker compose (used by `logrotate.conf`)
nginx-send-usr1:
	${COMPOSE} exec -T frontend /bin/bash -c 'kill -USR1 `pgrep -f "nginx: [m]aster"`'

PYTHON := "$(shell which python3 2>/dev/null || which python 2>/dev/null || which python2 2>/dev/null || echo "{python|python3|python2} not found")"
PYTHONPATH := $(shell $(PYTHON) -c "import sys; print(':'.join(sys.path[1:]))")
/etc/cron.daily/pkgserver: conf/cron.restart.conf
	SOURCEDIR=$(shell pwd) envsubst '$${SOURCEDIR} $${UID} $${GID}' < $< | sudo tee $@ >/dev/null
	sudo chmod +x $@
up: /etc/cron.daily/pkgserver

# Do a manual build of the docker container
local-build:
	docker build -t juliapackaging/pkgserver.jl ..

dev-up:
	echo "Stopping, clearing logs, building locally, relaunching, disabling watchtower and tail'ing logs"
	$(MAKE) down
	rm -rf logs
	$(MAKE) local-build
	$(MAKE) up
	$(MAKE) stop-watchtower
	sleep 1
	$(MAKE) logs
	

stop-watchtower:
	${COMPOSE} stop watchtower

trigger-watchtower:
	${COMPOSE} run --rm watchtower --cleanup --scope pkgserver.jl --run-once

logs:
	${COMPOSE} logs -f --tail=100
.PHONY: logs

# TODO: In the future we can remove /etc/cron.hourly/pkgserver but keep it here
# for now so that we can cleanup the files we installed in the past.
destroy:
	${COMPOSE} down -v --remove-orphans
	rm -rf logs storage build
	sudo rm -f /etc/cron.hourly/pkgserver /etc/cron.daily/pkgserver /etc/logrotate.d/pkgserver

restart:
	$(MAKE) down
	rm -rf build
	rm -rf storage/temp
	$(MAKE)

clean:
	rm -rf logs build

# Makefile debugging
print-%:
	@echo '$*=$(subst ','\'',$($*))'
