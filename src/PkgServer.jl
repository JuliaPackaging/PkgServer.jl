module PkgServer

using Pkg
using HTTP
using Base.Threads: Event, @spawn
import Base: fetch
using Random
using LibGit2
using FilesystemDatastructures
using SimpleBufferStream
using JSON3, StructTypes
using Sockets
using Sockets: InetAddr
using Dates
using Tar
using Gzip_jll

include("task_utils.jl")
include("resource.jl")
include("meta.jl")
include("dynamic.jl")
mutable struct RegistryMeta
    # Upstream registry URL (e.g. "https://github.com/JuliaRegistries/General")
    upstream_url::String
    # The latest hash we know about for this registry
    latest_hash::Union{Nothing,String}

    RegistryMeta(url::String) = new(url, nothing)
end

struct ServerConfig
    root::String
    listen_addr::InetAddr
    cache::SizeConstrainedFileCache
    registries::Dict{String,RegistryMeta}
    storage_servers::Vector{String}

    # Default server config constructor
    function ServerConfig(; listen_addr = InetAddr(ip"127.0.0.1", 8000),
                            storage_root = "/tmp/pkgserver",
                            registries = Dict(
                                "23338594-aafe-5451-b93e-139f81909106" =>
                                RegistryMeta("https://github.com/JuliaRegistries/General")
                            ),
                            storage_servers = [
                                "https://us-east.storage.juliahub.com",
                                "https://kr.storage.juliahub.com",
                            ],
                            keep_free=3*1024^3)
        # Right now, the only thing we store in `static/` is `/registries`
        mkpath(joinpath(storage_root, "static"))
        # Downloads get stored into `temp`
        mkpath(joinpath(storage_root, "temp"))
        return new(
            storage_root,
            listen_addr,
            SizeConstrainedFileCache(
                joinpath(storage_root, "cache"),
                TargetSizeKeepFree(keep_free),
                DiscardLRU()
            ),
            registries,
            sort!(storage_servers))
    end
end

# Initialize a default config that will get overridden by `start()` below
global config = ServerConfig()

function __init__()
    # Set default HTTP useragent
    HTTP.setuseragent!("PkgServer (HTTP.jl)")

    # Record our starting time
    global time_start = now()
end

function start(;kwargs...)
    # Create global config object
    global config = ServerConfig(;kwargs...)

    # Update registries first thing
    update_registries()

    @sync begin
        global last_registry_update
        global registry_task = @spawn while true
            last_registry_update = now()
            sleep(1)
            @try_printerror begin
                forget_failures()
                update_registries()
            end
        end
        @info("server listening", config.listen_addr)
        HTTP.listen(config.listen_addr.host, config.listen_addr.port) do http
            resource = http.message.target
            # If the user is asking for `/meta`, generate the requisite JSON object and send it back
            if resource == "/meta"
                serve_meta(http)
                return
            end
            if resource == "/meta/stats"
                serve_meta_stats(http)
                return
            end
            if resource == "/meta/siblings"
                serve_siblings(http)
                return
            end

            if resource  == "/registries"
                serve_file(http, joinpath(config.root, "static", "registries"), "text/plain", "identity")
                return
            end

            # If the user asked for something that is an actual resource, send it directly
            if occursin(resource_re, resource)
                path = fetch_resource(resource)
                if path !== nothing
                    serve_file(http, path, "application/tar",  "gzip")
                    return
                end
            end

            m = match(artifact_toml_re, resource)
            if m !== nothing
                artifact_path = fetch_resource(m.captures[1])
                if artifact_path !== nothing
                    serve_artifact_toml(http, artifact_path, m.captures[2])
                    return
                end
            end

            if occursin(r"^/*$", resource)
                path = joinpath(dirname(@__DIR__), "static", "index.html")
                if isfile(path)
                    content = ("text/html", "identity")
                    serve_file(http, path, content...)
                    return
                end
            end

            global total_misses += 1
            HTTP.setstatus(http, 404)
            startwrite(http)
        end
    end
end

end # module
