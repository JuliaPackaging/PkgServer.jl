using PkgServer, Pkg, TOML, HTTP, JSON3, Tar, Test

# You can either perform the following setup:
#  - Already-running PkgServer, located at $JULIA_PKG_SERVER
#  - PkgServer cache directory located at $PKG_SERVER_STORAGE_DIR
#
# Or you can leave those blank, and we'll start up a PkgServer for you,
# running on a background process.

# If these are not set, we will attempt to auto-initiate them.
server_process = nothing
code_dir = dirname(@__DIR__)
if isempty(get(ENV, "JULIA_PKG_SERVER", "")) || isempty(get(ENV, "JULIA_PKG_SERVER_STORAGE_ROOT", ""))
    # Start a background PkgServer as a separate process
    temp_dir = mktempdir()
    ENV["JULIA_PKG_SERVER"] = "http://127.0.0.1:8000"
    ENV["JULIA_PKG_SERVER_STORAGE_ROOT"] = temp_dir
    ENV["JULIA_PKG_SERVER_FQDN"] = "starfleet-central.pkg.julialang.org"

    @info("Automatically starting local PkgServer for testing at $(ENV["JULIA_PKG_SERVER"])")
    global server_process = run(`$(Base.julia_cmd()) --project=$(code_dir) $(code_dir)/bin/run_server.jl`; wait=false)
end

# Ensure that we don't end up spending time precompiling when we install stuff; it's useless
ENV["JULIA_PKG_PRECOMPILE_AUTO"]="0"

server_url = ENV["JULIA_PKG_SERVER"]
cache_dir = joinpath(ENV["JULIA_PKG_SERVER_STORAGE_ROOT"], "cache")

# Wrap all tests in a `try` block so that we can be certain we kill the
# server, even if we fail some tests.
try
    @info("Running test suite with configuration", server_url, cache_dir)
    include("tests.jl")
finally
    if server_process !== nothing
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
