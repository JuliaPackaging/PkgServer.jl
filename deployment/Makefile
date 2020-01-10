# Default to deploying with SSL
USE_SSL = 1

ifeq (1,$(USE_SSL))
COMPOSE_FILE := docker-compose.ssl.yml
else
COMPOSE_FILE := docker-compose.nossl.yml
endif
export COMPOSE_FILE

up:
	docker-compose up --build --remove-orphans -d

reload_pkgserver:
	docker-compose up --build --remove-orphans -d pkgserver

build:
	docker-compose build --pull

logs:
	docker-compose logs -f --tail=100

down:
	docker-compose down --remove-orphans

destroy:
	docker-compose down -v --remove-orphans
