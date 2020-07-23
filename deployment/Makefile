# Default to deploying without SSL
USE_SSL = 0

# Decide which `docker-compose` file to use, depending on whether we're using SSL or not
ifeq (1,$(USE_SSL))
COMPOSE_FILE := docker-compose.ssl.yml
else
COMPOSE_FILE := docker-compose.nossl.yml
endif
export COMPOSE_FILE


# We want to launch/build docker containers as our own UID, so we collect that from the environment
UID=$(shell id -u)
export UID

up: storage logs/nginx logs/pkgserver
	docker-compose up --build --remove-orphans -d

stop-watchtower:
	docker-compose stop watchtower

storage:
	mkdir -p $@
logs/nginx:
	mkdir -p $@
logs/pkgserver:
	mkdir -p $@

# Do a manual build of the docker container
# Note that watchtower will (by default) override this eventually,
# so it's only useful for quick tests
build:
	docker build -t juliapackaging/pkgserver.jl ..

logs:
	docker-compose logs -f --tail=100
.PHONY: logs

down:
	docker-compose down --remove-orphans

destroy:
	docker-compose down -v --remove-orphans
