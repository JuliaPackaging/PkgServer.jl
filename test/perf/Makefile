SRCDIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

K6 := docker run --rm -v $(SRCDIR):/config:ro -v $(SRCDIR)/results:/results --net=host -ti loadimpact/k6

up:
	docker-compose up -d --remove-orphans

down:
	docker-compose down -v --remove-orphans

results:
	mkdir -p $@
	chmod 777 results

smoke load hot_cache: up | results
	$(K6) run --out csv=/results/$@.csv --out influxdb=http://localhost:8086/k6 /config/$@.js
