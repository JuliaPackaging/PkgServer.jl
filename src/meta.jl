## Collected pieces of metadata that we will track over time
# This value will be overridden in __init__()
time_start = now()

# Last time we updated the registry
last_registry_update = now()

# Total served requests: incremented in serve_file()
total_hits = Int64(0)
# Total cache hits: incremented in fetch()
cached_hits = Int64(0)
# Total fetch successes: incremented in fetch()
fetch_hits = Int64(0)
# Total misses: incremented in start()
total_misses = Int64(0)
# Total payload bytes received from StorageServers
payload_bytes_received = Int64(0)
# Total payload bytes transmitted to clients
payload_bytes_transmitted = Int64(0)


## Functions to serve metadata about the PkgServer itself

const pkgserver_version = Ref{Union{Nothing,String}}(nothing)
function get_pkgserver_version()
    if pkgserver_version[] === nothing
        # Get PkgServer.jl's version and git sha
        version = Pkg.TOML.parsefile(joinpath(@__DIR__, "..", "Project.toml"))["version"]
        try
            repo = LibGit2.GitRepo(dirname(@__DIR__))
            gitsha = string(LibGit2.GitHash(LibGit2.GitCommit(repo, "HEAD")))
            pkgserver_version[] = "$(version)-$(gitsha)"
        catch
            pkgserver_version[] = "$(version)"
        end
    end
    return pkgserver_version[]
end

# Return the fully-qualified domain name of this server, if set.
const pkgserver_url = Ref{Union{Nothing,String}}(nothing)
function get_pkgserver_url()
    if pkgserver_url[] === nothing
        pkgserver_url[] = string("https://", get(ENV, "JULIA_PKG_SERVER_FQDN", "pkg.julialang.org"))
    end
    return pkgserver_url[]
end

# Return all officially-run PkgServer instances we know about
function get_pkgserver_siblings()
    regions = [
        # North America
        "us-west",
        "us-east",
        # Europe
        "eu-central",
        # Asia
        "in",
        "kr",
        "sg",
        # Special Chinese servers, serving from within-country
        "cn-southeast",
        "cn-east",
        "cn-northeast",
        # Australia
        "au",
    ]
    return [string("https://", region, ".pkg.julialang.org") for region in regions]
end

function get_num_hashnamed_files(dir)
    # If this directory doesn't exist, then we haven't cached anything!
    if !isdir(dir)
        return 0
    end

    num_files = 0
    for f in readdir(dir)
        # only consider things with a name length that is exactly a tree-hash (filters out in-progress downloads, etc...)
        # TODO: if we change hashes (e.g. SHA256), add that hash length here as well
        if length(f) != 40
            continue
        end

        # Only consider actual files
        f_path = joinpath(dir, f)
        if !isfile(f_path)
            continue
        end

        num_files += 1
    end
    return num_files
end

function get_num_pkgs_cached()
    cache_root = config.cache.root
    # If we don't even have a `package` directory, then don't worry about it
    if !isdir(joinpath(cache_root, "package"))
        return 0
    end

    num_pkgs_cached = 0
    for d in readdir(joinpath(cache_root, "package"))
        # Only consider things with a name that is exactly a UUID (filters out in-progress downloads, etc...)
        if length(d) != 36
            continue
        end

        # Only consider directories
        pkg_dir = joinpath(cache_root, "package", d)
        if !isdir(pkg_dir)
            continue
        end

        num_pkgs_cached += get_num_hashnamed_files(pkg_dir)
    end
    return num_pkgs_cached
end

function get_num_artifacts_cached()
    num_artifacts_cached = get_num_hashnamed_files(joinpath(config.cache.root, "artifact"))
end

function serve_json(http::HTTP.Stream, data)
    json = JSON3.write(data)
    HTTP.setheader(http, "Content-Length" => string(length(json)))
    HTTP.setheader(http, "Content-Type" => "application/json")
    if http.message.method == "GET"
        startwrite(http)
    end
    return write(http, json)
end

function serve_meta(http::HTTP.Stream)
    # We serve a JSON representation of some metadata about this PkgServer
    metadata = Dict(
        "pkgserver_version" => get_pkgserver_version(),
        "pkgserver_url" => get_pkgserver_url(),
        "julia_version" => string(VERSION),
        "start_time" => string(time_start),
        "last_registry_update" => string(last_registry_update),
        "maxrss" => Int(Sys.maxrss()),
    )
    return serve_json(http, metadata)
end

# Because we need to JSON-serialize cache entries, we must define the serialization strategy
StructTypes.StructType(::Type{FilesystemDatastructures.CacheEntry}) = StructTypes.Struct()
function serve_meta_stats(http::HTTP.Stream)
    # Serve a JSON representation of the top 100 most commonly requested resources
    stats = Dict(
        "lru" => config.cache.entries,
        "packages_cached" => get_num_pkgs_cached(),
        "artifacts_cached" => get_num_artifacts_cached(),

        ## Global response statistics:
        # Number of requests we've had total.  Should equal `cached_hits + fetch_hits`.
        "total_hits" => total_hits,
        # Number of requests served through the happy path; file was already present on disk.
        "cached_hits" => cached_hits,
        # Number of requests that were served by fetching it from the server.
        # Note; if three simultaneous requests come in for a file that we need to fetch,
        # we'll only fetch it once, but we'll stream the content back for all three, and
        # account all three as a `fetch_hit`.
        "fetch_hits" => fetch_hits,
        # Number of requests that could not be served
        "total_misses" => total_misses,
        "payload_bytes_received" => payload_bytes_received,
        "payload_bytes_transmitted" => payload_bytes_transmitted,
    )
    return serve_json(http, stats)
end

function serve_siblings(http::HTTP.Stream)
    return serve_json(http, get_pkgserver_siblings())
end
