#!/usr/bin/env julia
using PkgServer, Sockets, Logging, LoggingExtras, Dates

# Accept optional environment-based arguments
# Eventually, do this via Pkg preferences
pkgserver = get(ENV, "JULIA_PKG_SERVER", "http://0.0.0.0:8000")
try
    m = match(r"(https?://)?(.+):(\d+)", pkgserver)
    global host = m.captures[2]
    global port = parse(Int, m.captures[3])
catch
    @warn("Invalid JULIA_PKG_SERVER setting, ignoring and using default!")
    global host = "0.0.0.0"
    global port = 8000
end

storage_root = get(ENV, "JULIA_PKG_SERVER_STORAGE_ROOT", "/tmp/pkgserver")
storage_servers = strip.(split(get(ENV, "JULIA_PKG_SERVER_STORAGE_SERVERS", "https://us-east.storage.julialang.org,https://kr.storage.julialang.org"), ","))
log_dir = get(ENV, "JULIA_PKG_SERVER_LOGS_DIR", joinpath(storage_root, "logs"))

mkpath(storage_root)
mkpath(log_dir)

# Set up logging
const date_format = "yyyy-mm-dd HH:MM:SS"
timestamp_logger(logger) = TransformerLogger(logger) do log
    merge(log, (; message = "[$(Dates.format(now(), date_format))] $(log.message)"))
end

global_logger(TeeLogger(
    timestamp_logger(FileLogger(joinpath(log_dir, "pkgserver.log"); append=true)),
    current_logger(),
))

PkgServer.start(;
    listen_addr=Sockets.InetAddr(host, port),
    storage_root=storage_root,
    storage_servers=storage_servers,
)
