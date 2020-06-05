#!/usr/bin/env julia
using PkgServer, Sockets

# Accept optional environment-based arguments
# Eventually, do this via Pkg preferences
pkgserver = get(ENV, "JULIA_PKG_SERVER", "http://0.0.0.0:8000")
try
    m = match(r"(https?://)?(.+):(\d+)", pkgserver)
    global host = m.captures[2]
    global port = parse(Int, m.captures[3])
catch
    error("Invalid JULIA_PKG_SERVER setting!")
end

storage_root = get(ENV, "JULIA_PKG_SERVER_STORAGE_ROOT", "/tmp/pkgserver")
storage_servers = strip.(split(get(ENV, "JULIA_PKG_SERVER_STORAGE_SERVERS", "https://us-east.storage.julialang.org"), ","))

PkgServer.start(;
    listen_addr=Sockets.InetAddr(host, port),
    storage_root=storage_root,
    storage_servers=storage_servers,
)
