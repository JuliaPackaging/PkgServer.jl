#!/usr/bin/env julia
using PkgServer, Sockets

# This stub script only really used for testing, but feel free to adapt to your needs
host = "127.0.0.1"
port = 8001
PkgServer.start(;
    listen_addr=Sockets.InetAddr(host, port),
    storage_root=mktempdir(),
    dotflavors=[""],
)
