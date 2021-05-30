# Default target is to bring everything up
all: up

# Extract configuration from `.env` file
SERVER_FQDN := $(shell bash -c "source .env 2>/dev/null && echo \$$SERVER_FQDN")
PKGSERVERS := $(shell bash -c "source .env 2>/dev/null && echo \$$PKGSERVERS")

# We want to launch/build docker containers as our own UID, so we collect that from the environment
UID=$(shell id -u)
USER=$(shell id -u -n)
GROUP=$(shell id -g -n)
export UID USER GROUP

DIRS := logs/nginx build
$(DIRS):
	mkdir -p $@

build/loadbalancer.nginx.conf: conf/loadbalancer.nginx.conf .env | build
	@export FQDN=$(SERVER_FQDN); \
	export PKGSERVERS_SERVER_BLOCK="$$(printf "    server %s:8000;\n" $(PKGSERVERS))"; \
	envsubst '$${FQDN} $${PKGSERVERS_SERVER_BLOCK}' < $< > $@

up: $(DIRS) build/loadbalancer.nginx.conf
	docker-compose up --build --remove-orphans -d

down:
	docker-compose down --remove-orphans

# Rule to install logrotate configuration so that host-wide logrotate can
# perform the logrotations, as well as run `make nginx-send-usr1`.
PYTHON := "$(shell which python3 2>/dev/null || which python 2>/dev/null || which python2 2>/dev/null || echo "{python|python3|python2} not found")"
PYTHONPATH := $(shell $(PYTHON) -c "import sys; print(':'.join(sys.path[1:]))")
/etc/logrotate.d/loadbalancer: ../conf/logrotate.conf
	LOGDIR=$(shell pwd)/logs SOURCEDIR=$(shell pwd) PYTHONPATH=$(PYTHONPATH) envsubst < $< | sudo tee $@ >/dev/null
#up: /etc/logrotate.d/loadbalancer


# Rule to install cron.hourly configuration to tell nginx to reopen its logfiles
/etc/cron.hourly/loadbalancer: conf/cron.conf
	SOURCEDIR=$(shell pwd) PYTHONPATH=$(PYTHONPATH) envsubst < $< | sudo tee $@ >/dev/null
	sudo chmod +x $@
#up: /etc/cron.hourly/loadbalancer

# Rule to send nginx USR1 signal via docker-compose (used by `logrotate.conf`)
nginx-send-usr1:
	docker-compose exec -T loadbalancer /bin/bash -c 'kill -USR1 `pgrep -f "nginx: [m]aster"`'

stop-watchtower:
	docker-compose stop watchtower

logs:
	docker-compose logs -f --tail=100
.PHONY: logs

destroy:
	docker-compose down -v --remove-orphans
	rm -rf logs build

clean:
	rm -rf logs build

# Makefile debugging
print-%:
	@echo '$*=$(subst ','\'',$($*))'
