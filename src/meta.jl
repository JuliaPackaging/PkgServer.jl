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

function get_num_pkgs_cached(cache_dir)
    # If we don't even have a `package` directory, then don't worry about it
    if !isdir(joinpath(cache_dir, "package"))
        return 0
    end

    num_pkgs_cached = 0
    for d in readdir(joinpath(cache_dir, "package"))
        # Only consider things with a name that is exactly a UUID (filters out in-progress downloads, etc...)
        if length(d) != 36
            continue
        end

        # Only consider directories
        pkg_dir = joinpath(cache_dir, "package", d)
        if !isdir(pkg_dir)
            continue
        end

        num_pkgs_cached += get_num_hashnamed_files(pkg_dir)
    end
    return num_pkgs_cached
end

function get_num_artifacts_cached(cache_dir)
    num_artifacts_cached = get_num_hashnamed_files(joinpath(cache_dir, "artifact"))
end

function serve_meta(http::HTTP.Stream)
    # Get a count of how many things we've cached
    num_pkgs = get_num_pkgs_cached("cache")
    num_artifacts = get_num_artifacts_cached("cache")

    # We serve a JSON representation of some metadata about this PkgServer
    metadata = Dict(
        "pkgserver_version" => pkgserver_version,
        "julia_version" => string(VERSION),
        "packages_cached" => num_pkgs,
        "artifacts_cached" => num_artifacts,
    )

    # We generate an extremely simple subset of JSON here
    metadata_json = string(
        "{",
        join(["$(repr(k)): $(repr(v))" for (k, v) in metadata], ","),
        "}",
    )

    HTTP.setheader(http, "Content-Length" => string(length(metadata_json)))
    HTTP.setheader(http, "Content-Encoding" => "application/json")
    startwrite(http)
    write(http, metadata_json)
end
