SRCDIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Use docker compose if it exist, fall back to docker-compose
COMPOSE=$(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; else echo "docker-compose"; fi)

K6 := docker run --rm -v $(SRCDIR):/config:ro -v $(SRCDIR)/results:/results --net=host -ti loadimpact/k6

up:
	${COMPOSE} up -d --remove-orphans

down:
	${COMPOSE} down -v --remove-orphans

results:
	mkdir -p $@
	chmod 777 results

smoke load hot_cache soak: up | results
	$(K6) run --out csv=/results/$@.csv --out influxdb=http://localhost:8086/k6 /config/$@.js
