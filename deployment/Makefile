# Default target is to bring everything up
all: up

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
DISABLE_IPV6 := $(shell bash -c "source .env 2>/dev/null && echo \$$DISABLE_IPV6")

# If `DISABLE_TLS` is defined, use the `http` stanza instead of the `tls` one.
LISTEN_SRC := $(if $(DISABLE_TLS),conf/stanza_http.conf,conf/stanza_tls.conf)
MIRROR_SRC := conf/s3mirror.nginx.conf

# If `DISABLE_IPV6` is defined, don't add the `ipv6` servername
SERVERNAMES := $(PKG_SERVER_FQDN) pkgserver-$(PKG_SERVER_REGION).ip.cflo.at pkgserver-$(PKG_SERVER_REGION).ipv4.cflo.at $(if $(DISABLE_IPV6),,pkgserver-$(PKG_SERVER_REGION).ipv6.cflo.at)

# We want to launch/build docker containers as our own UID, so we collect that from the environment
UID=$(shell id -u)
GID=$(shell id -g)
USER=$(shell id -u -n)
GROUP=$(shell id -g -n)
export UID GID USER GROUP

DIRS := storage/cache storage/s3cache storage/static storage/temp
DIRS += logs/nginx logs/pkgserver build
$(DIRS):
	mkdir -p $@

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
	docker-compose up --build --remove-orphans -d

down:
	docker-compose down --remove-orphans

# Rule to install logrotate configuration so that host-wide logrotate can
# perform the logrotations, as well as run `make nginx-send-usr1`.
PYTHON := "$(shell which python3 2>/dev/null || which python 2>/dev/null || which python2 2>/dev/null || echo "{python|python3|python2} not found")"
PYTHONPATH := $(shell $(PYTHON) -c "import sys; print(':'.join(sys.path[1:]))")
/etc/logrotate.d/pkgserver: conf/logrotate.conf
	LOGDIR=$(shell pwd)/logs SOURCEDIR=$(shell pwd) PYTHONPATH=$(PYTHONPATH) envsubst < $< | sudo tee $@ >/dev/null
up: /etc/logrotate.d/pkgserver

include logrotate.make

# Rule to install cron.hourly configuration to tell nginx to reopen its logfiles
/etc/cron.hourly/pkgserver: conf/cron.logrotate.conf
	SOURCEDIR=$(shell pwd) PYTHONPATH=$(PYTHONPATH) envsubst < $< | sudo tee $@ >/dev/null
	sudo chmod +x $@
up: /etc/cron.hourly/pkgserver

# Rule to send nginx USR1 signal via docker-compose (used by `logrotate.conf`)
nginx-send-usr1:
	docker-compose exec -T frontend /bin/bash -c 'kill -USR1 `pgrep -f "nginx: [m]aster"`'

/etc/cron.daily/pkgserver: conf/cron.restart.conf
	SOURCEDIR=$(shell pwd) PYTHONPATH=$(PYTHONPATH) envsubst < $< | sudo tee $@ >/dev/null
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
	docker-compose stop watchtower

logs:
	docker-compose logs -f --tail=100
.PHONY: logs

destroy:
	docker-compose down -v --remove-orphans
	rm -rf logs storage build

restart:
	$(MAKE) down
	rm -rf build
	$(MAKE)

clean:
	rm -rf logs build

# Makefile debugging
print-%:
	@echo '$*=$(subst ','\'',$($*))'
