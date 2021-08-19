using PkgServer, Pkg, Pkg.TOML, HTTP, JSON3, Tar, Test

# You can either perform the following setup:
#  - Already-running PkgServer, located at $JULIA_PKG_SERVER
#  - PkgServer cache directory located at $PKG_SERVER_CACHE_DIR
#
# Or you can leave those blank, and we'll start up a PkgServer for you,
# running on a background process.

if VERSION < v"1.5"
    error("These tests require a PkgServer-compatible Julia version!")
end

# "Backport" of JuliaLang/julia#37206
function prepare_for_deletion(path::AbstractString)
    # Nothing to do for non-directories
    if !isdir(path)
        return
    end

    try chmod(path, filemode(path) | 0o333)
    catch; end
    for (root, dirs, files) in walkdir(path)
        for dir in dirs
            dpath = joinpath(root, dir)
            try chmod(dpath, filemode(dpath) | 0o333)
            catch; end
        end
    end
end

# If these are not set, we will attempt to auto-initiate them.
server_process = nothing
if isempty(get(ENV, "JULIA_PKG_SERVER", "")) || isempty(get(ENV, "JULIA_PKG_SERVER_STORAGE_ROOT", ""))
    # Start a background PkgServer as a separate process
    code_dir = dirname(@__DIR__)
    temp_dir = mktempdir()
    ENV["JULIA_PKG_SERVER"] = "http://127.0.0.1:8000"
    ENV["JULIA_PKG_SERVER_STORAGE_ROOT"] = temp_dir
    ENV["JULIA_PKG_SERVER_FQDN"] = "starfleet-central.pkg.julialang.org"

    @info("Automatically starting local PkgServer for testing at $(ENV["JULIA_PKG_SERVER"])")
    global server_process = run(`$(Base.julia_cmd()) --project=$(code_dir) $(code_dir)/bin/run_server.jl`; wait=false)
end

server_url = ENV["JULIA_PKG_SERVER"]
cache_dir = joinpath(ENV["JULIA_PKG_SERVER_STORAGE_ROOT"], "cache")

# Wrap all tests in a `try` block so that we can be certain we kill the
# server, even if we fail some tests.
try
    @info("Running test suite with configuration", server_url, cache_dir)
    include("tests.jl")
finally
    if server_process != nothing
        @info("Reaping automatically-started local PkgServer...")
        kill(server_process)
        wait(server_process)
        @info("Outputting testing PkgServer logs:")
        for f in filter(f -> endswith(f, "-pkgserver.log"), readdir("$(temp_dir)/logs"; join=true))
            println("$(f):")
            write(stdout, read(f))
        end
    end
end

(@isdefined temp_dir) && prepare_for_deletion(temp_dir)
