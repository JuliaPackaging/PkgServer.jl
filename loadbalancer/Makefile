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
UID:=$(shell id -u)
USER:=$(shell id -u -n)
GID:=$(shell id -g)
GROUP:=$(shell id -g -n)
export UID USER GID GROUP

DIRS := logs/nginx build
$(DIRS):
	mkdir -p $@

# Make sure nginx log files are created before starting nginx.
NGINX_CURRENT_LOGFILES := logs/nginx/access_${SERVER_FQDN}.log logs/nginx/error_${SERVER_FQDN}.log
$(NGINX_CURRENT_LOGFILES): logs/nginx
	sudo touch $@ && sudo chown $(UID):$(GID) $@ && chmod 0644 $@

# Make sure files have the expected permissions
filepermissions: logs/nginx $(NGINX_CURRENT_LOGFILES)
	sudo chown -R $(UID):$(GID) logs
.PHONY: filepermissions
up: filepermissions

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
/etc/logrotate.d/loadbalancer: ../deployment/conf/logrotate.conf
	LOGDIR=$(shell pwd)/logs SOURCEDIR=$(shell pwd) \
	envsubst '$${LOGDIR} $${SOURCEDIR} $${UID} $${USER} $${GID} $${GROUP}' < $< | sudo tee $@ >/dev/null
up: /etc/logrotate.d/loadbalancer

include ../deployment/logrotate.make

# Rule to send nginx USR1 signal via docker compose (used by `logrotate.conf`)
nginx-send-usr1:
	${COMPOSE} exec -T loadbalancer /bin/bash -c 'kill -USR1 `pgrep -f "nginx: [m]aster"`'

stop-watchtower:
	${COMPOSE} stop watchtower

logs:
	${COMPOSE} logs -f --tail=100
.PHONY: logs

# TODO: In the future we can remove /etc/cron.hourly/loadbalancer but keep it here
# for now so that we can cleanup the files we installed in the past.
destroy:
	${COMPOSE} down -v --remove-orphans
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
