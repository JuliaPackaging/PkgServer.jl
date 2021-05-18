#!/usr/bin/env julia
using PkgServer, Sockets, Logging, LoggingExtras, Dates

# Accept optional environment-based arguments
# Eventually, do this via Pkg preferences
pkgserver = get(ENV, "JULIA_PKG_SERVER", "http://[::]:8000")
try
    m = match(r"(https?://)?\[?([^\[\]]+)\]?:(\d+)", pkgserver)
    global host = m.captures[2]
    global port = parse(Int, m.captures[3])
catch ex
    @warn("Invalid JULIA_PKG_SERVER setting, ignoring and using default of [::]:8000!", pkgserver, ex)
    global host = "::"
    global port = 8000
end

storage_root = get(ENV, "JULIA_PKG_SERVER_STORAGE_ROOT", "/tmp/pkgserver")
storage_servers = strip.(split(get(ENV, "JULIA_PKG_SERVER_STORAGE_SERVERS", "https://us-east.storage.juliahub.com,https://kr.storage.juliahub.com"), ","))
log_dir = get(ENV, "JULIA_PKG_SERVER_LOGS_DIR", joinpath(storage_root, "logs"))

mkpath(storage_root)
mkpath(log_dir)

# Set up logging
const date_format = "yyyy-mm-dd HH:MM:SS"
timestamp_logger(logger) = TransformerLogger(logger) do log
    merge(log, (; message = "[$(Dates.format(now(), date_format))] $(log.message)"))
end

global_logger(TeeLogger(
    timestamp_logger(
        MinLevelLogger(
            DatetimeRotatingFileLogger(
                log_dir,
                string(raw"yyyy-mm-dd-\p\k\g\s\e\r\v\e\r.\l\o\g"),
            ),
            Logging.Info,
        ),
    ),
    current_logger(),
))

PkgServer.start(;
    listen_addr=Sockets.InetAddr(host, port),
    storage_root=storage_root,
    storage_servers=storage_servers,
)
