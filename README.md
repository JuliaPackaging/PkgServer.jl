# PkgServer

Reference implementation of a Julia Pkg server, providing advanced package serving and caching capabilities.

## Usage

See [`bin/run_server.jl`](bin/run_server.jl) for an example on how to run a PkgServer locally.  For a quick, localhost-only setup for development purposes:
```bash
# Enter package directory
$ cd PkgServer.jl
# Launch server to run in foreground
$ julia --project bin/run_server.jl
```

Then, start a 1.4 or newer version of Julia, referring all Pkg operations to this package server::
```
$ JULIA_PKG_SERVER=http://localhost:8000 julia
```

## Deployment

See the [deployment](deployment) directory for an example `docker-compose` setup to easily deploy your own mirror Pkg server, with an optional SSL interface provided through `nginx` and `letsencrypt`.
