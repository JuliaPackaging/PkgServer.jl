# Default target is to bring everything up
all: up

# Extract configuration from `.env` file
PKG_SERVER_FQDN := $(shell bash -c "source .env 2>/dev/null && echo \$$PKG_SERVER_FQDN")
S3_MIRROR_FQDN  := $(shell bash -c "source .env 2>/dev/null && echo \$$S3_MIRROR_FQDN")

# If a FQDN is not given, we use the plain HTTP stanza for the pkg server/s3 mirror
PKG_SERVER_LISTEN_SRC := $(if $(PKG_SERVER_FQDN),conf/stanza_tls.conf,conf/stanza_http.conf)
S3_MIRROR_LISTEN_SRC  := $(if  $(S3_MIRROR_FQDN),conf/stanza_tls.conf,conf/stanza_http.conf)

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
build/pkgserver.nginx.conf: conf/pkgserver.nginx.conf ${PKG_SERVER_LISTEN_SRC} | build
	@export FQDN=$(PKG_SERVER_FQDN); \
	export LISTEN_BLOCK_SRC=${PKG_SERVER_LISTEN_SRC}; \
	export LISTEN_BLOCK="$$(envsubst '$${FQDN}' < "${PKG_SERVER_LISTEN_SRC}")"; \
	envsubst '$${LISTEN_BLOCK_SRC} $${LISTEN_BLOCK} $${FQDN}' < $< > $@

# Only build the s3mirror if S3_MIRROR_FQDN is given
ifneq ($(S3_MIRROR_FQDN),)
build/s3mirror.nginx.conf: conf/s3mirror.nginx.conf ${S3_MIRROR_LISTEN_SRC} | build
	@export FQDN=$(S3_MIRROR_FQDN); \
	export LISTEN_BLOCK_SRC=${S3_MIRROR_LISTEN_SRC}; \
	export LISTEN_BLOCK="$$(envsubst '$${FQDN}' < "${S3_MIRROR_LISTEN_SRC}")"; \
	envsubst '$${LISTEN_BLOCK_SRC} $${LISTEN_BLOCK} $${FQDN}' < $< > $@
up: build/s3mirror.nginx.conf
endif

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

# If `cron.daily/logrotate` exists, we better move it over to `cron.hourly`, so that we can do hourly log rotations
ifneq ($(wildcard /etc/cron.daily/logrotate),)
/etc/cron.hourly/logrotate: /etc/cron.daily/logrotate
# Use `dpkg-divert`, if possible
ifneq ($(shell which dpkg-divert 2>/dev/null),)
	sudo dpkg-divert --add --rename --divert /etc/cron.hourly/logrotate /etc/cron.daily/logrotate
else
	sudo mv $< $@
endif
up: /etc/cron.hourly/logrotate
endif


# Rule to install cron.hourly configuration to tell nginx to reopen its logfiles
/etc/cron.hourly/pkgserver: conf/cron.conf
	SOURCEDIR=$(shell pwd) PYTHONPATH=$(PYTHONPATH) envsubst < $< | sudo tee $@ >/dev/null
	sudo chmod +x $@
up: /etc/cron.hourly/pkgserver

# Rule to send nginx USR1 signal via docker-compose (used by `logrotate.conf`)
nginx-send-usr1:
	docker-compose exec -T frontend /bin/bash -c 'kill -USR1 `pgrep -f "nginx: [m]aster"`'

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

clean:
	rm -rf logs build

# Makefile debugging
print-%:
	@echo '$*=$(subst ','\'',$($*))'
