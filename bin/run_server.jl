#!/usr/bin/env julia

# Accept optional environment-based arguments
host = get(ENV, "PKGSERVER_HOST", "127.0.0.1")
port = parse(Int, get(ENV, "PKGSERVER_PORT", "8000"))
storage_servers = strip.(split(get(ENV, "PKGSERVER_STORAGESERVERS", "https://pkg.julialang.org"), ","))

using PkgServer
empty!(PkgServer.STORAGE_SERVERS)
append!(PkgServer.STORAGE_SERVERS, storage_servers)
PkgServer.start(;host=host, port=port)
