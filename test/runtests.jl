using PkgServer, Pkg, HTTP, JSON3, Tar
using Test

# You can either perform the following setup:
#  - Already-running PkgServer, located at $JULIA_PKG_SERVER
#  - PkgServer cache directory located at $PKG_SERVER_CACHE_DIR
#
# Or you can leave those blank, and we'll start up a PkgServer for you,
# running on a background process.

if VERSION < v"1.4"
    error("These tests require a PkgServer-compatible Julia version!")
end

# If these are not set, we will attempt to auto-initiate them.
server_process = nothing
if isempty(get(ENV, "JULIA_PKG_SERVER", "")) || isempty(get(ENV, "JULIA_PKG_SERVER_STORAGE_ROOT", ""))
    # Start a background PkgServer as a separate process
    code_dir = dirname(@__DIR__)
    temp_dir = mktempdir()
    ENV["JULIA_PKG_SERVER"] = "http://127.0.0.1:8000"
    ENV["JULIA_PKG_SERVER_STORAGE_ROOT"] = temp_dir

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
        run(`cat $(temp_dir)/logs/pkgserver.log`)
    end    
end
