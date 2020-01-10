# Deployment configuration

Deployment of a new PkgServer is as easy as filling out a `.env` file and running `make`.  The `.env` file controls the customization of the PkgServer and associated containers.  The values that should be set are listed in `.env.example`, along with whether the value is required or not.  There are two separate `docker-compose.yml` configurations listed here; a non-SSL version, and an SSL version.  The non-SSL version just runs the the pkg server directly on port `8000`.  The SSL version runs an `nginx` SSL terminator (hooked up with `letsencrypt`), then `proxy_pass`'es the decrypted traffic to a PkgServer instance running within a separate container.

To avoid needing to memorize arcane `docker-compose` commands, a handy `Makefile` is provided to ease usage of `docker-compose`.  Valid make verbs are `up`, `build`, `logs`, `down`, `destroy`, etc....  By default, the SSL version will be deployed, to build/deploy the non-ssl version, invoke `make` with the `USE_SSL=0` flag.

This deployment also includes a webhook listener that can be hooked up with `GitHub` to auto-rebuild the PkgServer docker container upon new commits being merged to a particular branch (such as `master`)
