# Default target is to bring everything up
all: up

# Makefile hacks
COMMA:=,
SPACE:=$(eval) $(eval)

# Use docker compose if it exist, fall back to docker-compose
COMPOSE=$(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; else echo "docker-compose"; fi)

# Extract configuration from `.env` file
SERVER_REGION := $(shell bash -c "source .env 2>/dev/null && echo \$$SERVER_REGION")
PKGSERVERS := $(shell bash -c "source .env 2>/dev/null && echo \$$PKGSERVERS")

# Set the server FQDN to `region.pkg.julialang.org`
SERVER_FQDN := $(SERVER_REGION).pkg.julialang.org
export SERVER_FQDN

# We want to launch/build docker containers as our own UID, so we collect that from the environment
UID=$(shell id -u)
USER=$(shell id -u -n)
GROUP=$(shell id -g -n)
export UID USER GROUP

DIRS := logs/nginx build
$(DIRS):
	mkdir -p $@

# Generate the loadbalancer configuration
build/loadbalancer.nginx.conf: conf/loadbalancer.nginx.conf .env | build
	@export REGION=$(SERVER_REGION); \
	export FQDN=$(SERVER_FQDN); \
	export PKGSERVERS_SERVER_BLOCK="$$(printf "    server pkgserver-%s.ipv6.cflo.at:443;\n" $(PKGSERVERS))"; \
	envsubst '$${FQDN} $${REGION} $${PKGSERVERS_SERVER_BLOCK}' < $< > $@
up: build/loadbalancer.nginx.conf

# Generate static list of child servers we hide behind our broad, load-balancing shoulders
build/children.json: .env | build
	@echo "[$(subst $(SPACE),$(COMMA),$(patsubst %,\"https://%.pkg.julialang.org\",$(PKGSERVERS)))]" > $@
up: build/children.json

up: $(DIRS) build/loadbalancer.nginx.conf
	${COMPOSE} up --build --remove-orphans -d

down:
	${COMPOSE} down --remove-orphans

# Rule to install logrotate configuration so that host-wide logrotate can
# perform the logrotations, as well as run `make nginx-send-usr1`.
PYTHON := "$(shell which python3 2>/dev/null || which python 2>/dev/null || which python2 2>/dev/null || echo "{python|python3|python2} not found")"
PYTHONPATH := $(shell $(PYTHON) -c "import sys; print(':'.join(sys.path[1:]))")
/etc/logrotate.d/loadbalancer: ../deployment/conf/logrotate.conf
	LOGDIR=$(shell pwd)/logs SOURCEDIR=$(shell pwd) PYTHONPATH=$(PYTHONPATH) envsubst < $< | sudo tee $@ >/dev/null
up: /etc/logrotate.d/loadbalancer

# Rule to install cron.hourly configuration to tell nginx to reopen its logfiles
/etc/cron.hourly/loadbalancer: ../deployment/conf/cron.logrotate.conf
	SOURCEDIR=$(shell pwd) PYTHONPATH=$(PYTHONPATH) envsubst < $< | sudo tee $@ >/dev/null
	sudo chmod +x $@
up: /etc/cron.hourly/loadbalancer

include ../deployment/logrotate.make

# Rule to send nginx USR1 signal via docker compose (used by `logrotate.conf`)
nginx-send-usr1:
	${COMPOSE} exec -T loadbalancer /bin/bash -c 'kill -USR1 `pgrep -f "nginx: [m]aster"`'

stop-watchtower:
	${COMPOSE} stop watchtower

logs:
	${COMPOSE} logs -f --tail=100
.PHONY: logs

destroy:
	${COMPOSE} down -v --remove-orphans
	rm -rf logs build

restart:
	$(MAKE) down
	rm -rf build
	$(MAKE)

clean:
	rm -rf logs build

# Makefile debugging
print-%:
	@echo '$*=$(subst ','\'',$($*))'
