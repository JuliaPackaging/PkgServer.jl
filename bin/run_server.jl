#!/usr/bin/env julia

# Accept optional environment-based arguments
host = get(ENV, "PKGSERVER_HOST", "127.0.0.1")
port = parse(Int, get(ENV, "PKGSERVER_PORT", "8000"))
storage_servers = split(get(ENV, "PKGSERVER_STORAGESERVERS", "http://127.0.0.1"), ",")

using PkgServer
empty!(PkgServer.STORAGE_SERVERS)
append!(PkgServer.STORAGE_SERVERS, storage_servers)
PkgServer.start(;host=host, port=port)
