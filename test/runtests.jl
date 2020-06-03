using PkgServer, Pkg, HTTP, JSON
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
if isempty(get(ENV, "JULIA_PKG_SERVER", "")) || isempty(get(ENV, "JULIA_PKG_SERVER_CACHE_DIR", ""))
    @info("Automatically starting local PkgServer for testing at http://127.0.0.1:8000")
    # Start a background PkgServer as a separate process
    code_dir = dirname(@__DIR__)
    temp_dir = mktempdir(; cleanup=false)
    cd(temp_dir) do
        global server_process = run(`$(Base.julia_cmd()) --project=$(code_dir) $(code_dir)/bin/run_server.jl`; wait=false)

        ENV["JULIA_PKG_SERVER"] = "http://127.0.0.1:8000"
        ENV["JULIA_PKG_SERVER_CACHE_DIR"] = joinpath(temp_dir, "cache")

        # Tell Julia to cleanup this directory at process exit
        Base.Filesystem.temp_cleanup_later(temp_dir)
    end
end

server_url = ENV["JULIA_PKG_SERVER"]
cache_dir = ENV["JULIA_PKG_SERVER_CACHE_DIR"]

# Wrap all tests in a `try` block so that we can be certain we kill the
# server, even if we fail some tests.
try
    include("tests.jl")
finally
    if server_process != nothing
        @info("Reaping automatically-started local PkgServer...")
        kill(server_process)
        wait(server_process)
    end    
end
