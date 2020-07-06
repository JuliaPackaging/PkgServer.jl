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


## Functions to serve metadata about the PkgServer itself

function get_pkgserver_version()
    # Get PkgServer.jl's version and git sha
    version = Pkg.TOML.parsefile(joinpath(@__DIR__, "..", "Project.toml"))["version"]
    try
        repo = LibGit2.GitRepo(dirname(@__DIR__))
        gitsha = string(LibGit2.GitHash(LibGit2.GitCommit(repo, "HEAD")))
        return "$(version)-$(gitsha)"
    catch
        return "$(version)"
    end
end
# We store this once, since it's not exactly going to change
const pkgserver_version = get_pkgserver_version()

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

function serve_json(http::HTTP.Stream, data::Dict)
    json = JSON3.write(data)
    HTTP.setheader(http, "Content-Length" => string(length(json)))
    HTTP.setheader(http, "Content-Type" => "application/json")
    startwrite(http)
    return write(http, json)
end

function serve_meta(http::HTTP.Stream)
    # We serve a JSON representation of some metadata about this PkgServer
    metadata = Dict(
        "pkgserver_version" => pkgserver_version,
        "julia_version" => string(VERSION),
        "start_time" => string(time_start),
        "last_registry_update" => string(last_registry_update),
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
        # Global response statistics
        "total_hits" => total_hits,
        "cached_hits" => cached_hits,
        "fetch_hits" => fetch_hits,
        "total_misses" => total_misses,
    )
    return serve_json(http, stats)
end
