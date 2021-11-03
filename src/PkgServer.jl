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
    # The hash (for each flavor) for each registry
    hashes::Dict{String,String}

    function RegistryMeta(url::String)
        # Check to ensure this path actually exists
        if !url_exists(url)
            throw(ArgumentError("Invalid unreachable registry '$(url)'"))
        end

        # Auto-detect a repository that doesn't have `.git` at the end but could
        git_url = string(url, ".git")
        if !endswith(url, ".git") && url_exists(git_url)
            url = git_url
        end
        return new(url, Dict{String,String}())
    end
end

struct ServerConfig
    root::String
    listen_addr::InetAddr
    listen_server::Ref{Any}
    cache::SizeConstrainedFileCache
    registries::Dict{String,RegistryMeta}
    storage_servers::Vector{String}
    dotflavors::Vector{String}

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
                            dotflavors = [
                                ".eager",
                                ".conservative",
                            ],
                            keep_free=3*1024^3)
        # Right now, the only thing we store in `static/` is `/registries`
        mkpath(joinpath(storage_root, "static"))
        # Downloads get stored into `temp`
        mkpath(joinpath(storage_root, "temp"))
        # Files get stored into `cache`
        mkpath(joinpath(storage_root, "cache"))
        return new(
            storage_root,
            listen_addr,
            Ref(nothing),
            SizeConstrainedFileCache(
                joinpath(storage_root, "cache"),
                TargetSizeKeepFree(keep_free),
                DiscardLRU()
            ),
            registries,
            sort!(storage_servers),
            dotflavors,
        )
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
    @info("Loading initial Server Config")
    # Create global config object
    global config = ServerConfig(;kwargs...)
    flavorless_mode = config.dotflavors == [""]

    # Update registries first thing
    @info("Performing initial registry update")
    initial_update_changed = any(update_registries.(config.dotflavors))
    if !flavorless_mode && !initial_update_changed
        @warn("Flavorless storage servers detected, falling back to flavorless mode")
        flavorless_mode = true
        empty!(config.dotflavors)
        push!(config.dotflavors, "")
    end
    if !initial_update_changed && !any(update_registries.(config.dotflavors))
        error("Unable to get initial registry update!")
    end
    global last_registry_update = now()

    # Experimental.@sync throws if _any_ of the tasks fail
    Base.Experimental.@sync begin
        global registry_update_task = @spawn begin
            while true
                sleep(1)
                @try_printerror begin
                    forget_failures()
                    update_registries.(config.dotflavors)
                    last_registry_update = now()
                end
            end
        end

        # Registry watchdog; if `last_registry_update` doesn't change
        # for more than 20 minutes, we kill ourselves so that we can restart
        max_time_lag = Second(20 * 60)
        global registry_watchdog_task = @spawn begin
            while true
                time_lag = now() - last_registry_update
                if time_lag > max_time_lag
                    task_result = try fetch(registry_update_task); catch err; err end
                    @error "registry update watchdog timer tripped" time_lag max_time_lag task_result
                    exit(1)
                end
                sleep(max_time_lag.value)
            end
        end

        listen_server = Sockets.listen(config.listen_addr)
        config.listen_server[] = listen_server
        @info("server listening", config.listen_addr)
        num_requests = 0
        HTTP.listen(config.listen_addr.host, config.listen_addr.port; server=listen_server, max_connections=10) do http
            num_requests += 1
            resource = http.message.target
            request_id = HTTP.header(http, "X-Request-ID", "")
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
            if resource == "/meta/children"
                # PkgServers don't have children, but to be good neighbors,
                # we return an empty list here, to make it easier to recurse.
                serve_children(http)
                return
            end
            if resource == "/meta/parents"
                serve_parents(http)
                return
            end
            if resource == "/robots.txt"
                serve_robots_txt(http)
                return
            end
            
            if resource == "/registries" && !flavorless_mode
                # If they're asking for just "/registries", inspect headers to figure
                # out which registry flavor they actually want, and if none is given,
                # give them `conservative` by default, unless they are self-reporting
                # as a CI bot, in which case we'll always point them to `eager`.
                ci = any([v == "t" for (k, v) in filter(!isempty, split(HTTP.header(http, "Julia-CI-Variables", ""), ";"))])
                flavor = HTTP.header(http, "Julia-Registry-Preference", ci ? "eager" : "conservative")
                serve_redirect(http, "/registries.$(flavor)")
                return
            end

            if occursin(r"^/registries(\.[a-z]+$)?", resource)
                filepath = joinpath(config.root, "static", basename(resource))
                if !isfile(filepath)
                    HTTP.setstatus(http, 404)
                    startwrite(http)
                    return
                end
                open(filepath) do io
                    serve_file(http, io, "text/plain")
                end
                return
            end

            # If the user asked for something that is an actual resource, send it directly
            if occursin(resource_re, resource)
                # If the resource already exists locally, yay!  Serve it and quit.
                resource_path = resource_filepath(resource)
                io = try_open(resource_path)
                if io !== nothing
                    hit!(config.cache, resource[2:end])
                    serve_file(http, io, "application/x-gzip")
                    close(io)
                    return
                end

                # If it doesn't exist locally, let's request a fetch on that resource.
                # This will return either `nothing` (e.g. resource does not exist) or
                # a `DownloadState` that represents a partial download.
                dl_state = fetch_resource(resource, request_id)
                if dl_state !== nothing
                    HTTP.setheader(http, "X-Cache-Miss" => "miss")
                    stream_path = temp_resource_filepath(resource)
                    # Wait until `stream_path` is created
                    while !isfile(stream_path) && dl_state.dl_task.state != :done
                        sleep(0.001)
                    end
                    # Try to serve `stream_path` file
                    stream_io = try_open(stream_path)
                    if stream_io !== nothing
                        serve_file(http, stream_io, "application/x-gzip";
                                   content_length=dl_state.content_length,
                                   dl_task=dl_state.dl_task)
                        close(stream_io)
                        return
                    end

                    # If we couldn't open `stream_path`, it may be because the file finished
                    # downloading since we last checked 20 lines ago.  Check again.
                    io = try_open(resource_path)
                    if io !== nothing
                        serve_file(http, io, "application/x-gzip")
                        close(io)
                        return
                    end
                end
            end

            # If a user asks for an `Artifacts.toml` for a particular artifact, we'll generate
            # one for them on the fly.
            m = match(artifact_toml_re, resource)
            if m !== nothing
                artifact_resource = m.captures[1]
                artifact_name = m.captures[2]

                # If we don't actually have the artifact locally, we need to fetch it first.
                artifact_path = resource_filepath(artifact_resource)
                if !isfile(artifact_path)
                    dl_state = fetch_resource(artifact_resource, request_id)
                    if dl_state !== nothing
                        # We actually need to wait for the download to finish so that we can
                        # calculate the SHA256 hash of the tarball.
                        wait(dl_state.dl_task)
                    end
                end

                # We check again, because it's possible the above download failed.
                if isfile(artifact_path)
                    serve_artifact_toml(http, artifact_path, artifact_name)
                    return
                end
            end

            if occursin(r"^/*$", resource)
                path = joinpath(dirname(@__DIR__), "static", "index.html")
                io = try_open(path)
                if io !== nothing
                    serve_file(http, io, "text/html")
                    close(io)
                    return
                end
            end

            global total_misses += 1
            HTTP.setstatus(http, 404)
            startwrite(http)
        end
    end
end

# precompilation                                                                                                                    
include(joinpath(dirname(@__DIR__), "deps", "precompile.jl"))
if get(ENV, "PKGSERVER_GENERATING_PRECOMPILE", nothing) === nothing
    _precompile_()
end

end # module
