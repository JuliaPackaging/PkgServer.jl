# Default target is to bring everything up
all: up

# Makefile hacks
COMMA:=,
SPACE:=$(eval) $(eval)

# Extract configuration from `.env` file
SERVER_REGION := $(shell bash -c "source .env 2>/dev/null && echo \$$SERVER_REGION")
PKGSERVERS := $(shell bash -c "source .env 2>/dev/null && echo \$$PKGSERVERS")
CDN_REDIRECT_URL := $(shell bash -c "source .env 2>/dev/null && echo \$$CDN_REDIRECT_URL")
S3_MIRROR_BUCKET_LIST := $(shell bash -c "source .env 2>/dev/null && echo \$$S3_MIRROR_BUCKET_LIST")
DISABLE_TLS := $(shell bash -c "source .env 2>/dev/null && echo \$$DISABLE_TLS")
MIRROR_SRC := conf/s3mirror.nginx.conf
LISTEN_SRC := $(if $(DISABLE_TLS),conf/stanza_http.conf,conf/stanza_tls.conf)

# Set the server FQDN to `region.pkg.julialang.org`
SERVER_FQDN := $(SERVER_REGION).pkg.julialang.org
export SERVER_FQDN

# We want to launch/build docker containers as our own UID, so we collect that from the environment
UID:=$(shell id -u)
USER:=$(shell id -u -n)
GID:=$(shell id -g)
GROUP:=$(shell id -g -n)
export UID USER GID GROUP

DIRS += build logs/nginx
DIRS += logs/pkgserver1 storage/pkgserver1/cache storage/pkgserver1/s3cache storage/pkgserver1/static storage/pkgserver1/temp
DIRS += logs/pkgserver2 storage/pkgserver2/cache storage/pkgserver2/s3cache storage/pkgserver2/static storage/pkgserver2/temp
DIRS += storage/cache storage/s3cache
$(DIRS):
	mkdir -p $@

# Make sure nginx log files are created before starting nginx. Without this the
# nginx master process (running as root) creates them with root as owner.
NGINX_CURRENT_LOGFILES := logs/nginx/access_${SERVER_FQDN}.log logs/nginx/error_${SERVER_FQDN}.log
$(NGINX_CURRENT_LOGFILES): logs/nginx .env
	touch $@
	chmod 0644 $@

# Make sure files have the expected permissions: the nginx master process runs
# as root and sometimes files created by this process trips up the package
# server (which runs as a regular user).
filepermissions: $(DIRS) $(NGINX_CURRENT_LOGFILES)
	sudo chown -R $(UID):$(GID) logs storage
.PHONY: filepermissions
up: filepermissions

# Generate the loadbalancer configuration
build/loadbalancer.nginx.conf: conf/loadbalancer.nginx.conf $(LISTEN_SRC) $(MIRROR_SRC) .env | build
	@export FQDN=$(SERVER_FQDN); \
	export SERVERNAMES=$(SERVER_FQDN); \
	export PKGSERVERS_SERVER_BLOCK="$$(printf "    server %s;\n" $(PKGSERVERS))"; \
	export LISTEN_BLOCK="$$(envsubst '$${FQDN} $${SERVERNAMES}' < "$(LISTEN_SRC)")"; \
	if [ -z "$(CDN_REDIRECT_URL)" ]; then \
		export CDN_REDIRECT_BLOCK="$$(printf "    %s location ~ /(registry|package|artifact)/ { return 302 ...; }\n" \#)"; \
	else \
		export CDN_REDIRECT_BLOCK="$$(printf "    location ~ /(registry|package|artifact)/ { return 302 %s\$$uri\$$resource_ext; }\n" $(CDN_REDIRECT_URL))"; \
	fi; \
	MIRROR_BLOCK=""; \
	NL="$$(printf '\na')"; NL="$${NL%a}"; \
	if [ -n "$(S3_MIRROR_BUCKET_LIST)" ]; then \
		for S3_BUCKET in $(S3_MIRROR_BUCKET_LIST); do \
			export S3_BUCKET; \
			export MIRROR_BLOCK="$${MIRROR_BLOCK}$${NL}$$(envsubst '$${S3_BUCKET}' < "$(MIRROR_SRC)")"; \
		done; \
	fi; \
	envsubst '$${FQDN} $${LISTEN_BLOCK} $${PKGSERVERS_SERVER_BLOCK} $${CDN_REDIRECT_BLOCK} $${MIRROR_BLOCK}' < $< > $@
up: build/loadbalancer.nginx.conf

up: $(DIRS) build/loadbalancer.nginx.conf
	docker compose up --build --remove-orphans -d

down:
	docker compose down --remove-orphans

# Rule to install logrotate configuration so that host-wide logrotate can
# perform the logrotations, as well as run `make nginx-send-usr1`.
/etc/logrotate.d/loadbalancer: ../deployment/conf/logrotate.conf
	LOGDIR=$(shell pwd)/logs SOURCEDIR=$(shell pwd) \
	envsubst '$${LOGDIR} $${SOURCEDIR} $${UID} $${USER} $${GID} $${GROUP}' < $< | sudo tee $@ >/dev/null
up: /etc/logrotate.d/loadbalancer

include ../deployment/logrotate.make

# Rule to send nginx USR1 signal via docker compose (used by `logrotate.conf`)
nginx-send-usr1:
	docker compose kill --signal=SIGUSR1 loadbalancer

# Rule to send nginx HUP signal to reload configuration
nginx-send-hup:
	docker compose kill --signal=SIGHUP loadbalancer

logs:
	docker compose logs -f --tail=100
.PHONY: logs

# TODO: In the future we can remove /etc/cron.hourly/loadbalancer but keep it here
# for now so that we can cleanup the files we installed in the past.
destroy:
	docker compose down -v --remove-orphans
	rm -rf logs build
	sudo rm -f /etc/cron.hourly/loadbalancer /etc/logrotate.d/loadbalancer

restart:
	$(MAKE) down
	rm -rf build
	$(MAKE)

clean:
	rm -rf logs build

# Makefile debugging
print-%:
	@echo '$*=$(subst ','\'',$($*))'
