# Deployment configuration

We support two deployment configurations: a non-SSL version, and an SSL version.  The non-SSL version just runs the the pkg server directly on port `80`.  The SSL version runs an `nginx` SSL terminator (hooked up with `letsencrypt`), then `proxy_pass`'es the decrypted traffic to a PkgServer instance running within a separate container.

To avoid needing to memorize arcane `docker-compose` commands, a handy `Makefile` is provided to ease usage of `docker-compose`.  Valid make verbs are `up`, `build`, `logs`, `down`, etc....  By default, the SSL version will be deployed, to build/deploy the non-ssl version, invoke `make` with the `USE_SSL=0` flag.

When using SSL, you must provide a `.env` file with the values `FQDN` and `CERTBOT_EMAIL` defined in order for certbot to be able to automatically get/renew SSL certificates for your SSL termination.  See the `.env.example` file for what it should look like.
