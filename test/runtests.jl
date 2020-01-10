using PkgServer, Pkg, HTTP
using Test

# You can either perform the following setup:
#  - Already-running PkgServer, located at $JULIA_PKG_SERVER
#  - PkgServer cache directory located at $PKG_SERVER_CACHE_DIR
#
# Or you can leave those blank, and we'll start up a PkgServer for you, running on a background task.

if VERSION < v"1.4"
    error("These tests require a PkgServer-compatible Julia version!")
end

# If these are not set, we will attempt to auto-initiate them.
if isempty(get(ENV, "JULIA_PKG_SERVER", "")) || isempty(get(ENV, "JULIA_PKG_SERVER_CACHE_DIR", ""))
    # Start a background PkgServer
    mktempdir() do temp_dir
        ENV["JULIA_PKG_SERVER"] = "http://127.0.0.1:8000"
        ENV["JULIA_PKG_SERVER_CACHE_DIR"] = joinpath(temp_dir, "cache")
        @async begin
            cd(temp_dir) do
                PkgServer.start(;host="127.0.0.1", port=8000)
            end
        end
    end
end

server_url = ENV["JULIA_PKG_SERVER"]
cache_dir = ENV["JULIA_PKG_SERVER_CACHE_DIR"]

# Server may be sleepy and still waking up; wait a few seconds until it's responding properly
t_start = time()
while true
    # Try to get an HTTP 200 OK on /registries
    response = HTTP.get("$(server_url)/registries")
    if response.status == 200
        break
    end

    # If we've been trying this for more than 10s, error out
    if (time() - t_start) >= 10
        error("Unable to hit testing server at $(server_url)/registries, get HTTP $(response.status)")
    end
end

@testset "/registries" begin
    # Test that we get a sensical answer for /registries
    response = HTTP.get("$(server_url)/registries")
    @test response.status == 200
    registry_url = chomp(String(response.body))
    @test match(r"^/registry/([a-z0-9]+-){4}[a-z0-9]+/[a-z0-9]+$", registry_url) != nothing
    registry_uuid, registry_treehash = split(registry_url, "/")[3:4]

    # Test asking for that registry directly, unpacking it and verifying the treehash
    mktemp() do tarball_path, tarball_io
        response = HTTP.get("$(server_url)/registry/$(registry_uuid)/$(registry_treehash)"; response_stream=tarball_io)
        close(tarball_io)
        @test response.status == 200
        @test registry_treehash == PkgServer.tarball_git_hash(tarball_path)
    end

    # Verify that these files exist within the cache
    @test isfile(joinpath(cache_dir, "registries"))
    @test isfile(joinpath(cache_dir, "registry", registry_uuid, registry_treehash))
end

function with_depot_path(f::Function, dp::Vector{String})
    OLD_DEPOT_PATH = copy(Base.DEPOT_PATH)
    empty!(Base.DEPOT_PATH)
    append!(Base.DEPOT_PATH, dp)
    try
        f()
    finally
        empty!(Base.DEPOT_PATH)
        append!(Base.DEPOT_PATH, OLD_DEPOT_PATH)
    end
end

@testset "Package Installation" begin
    mktempdir() do temp_dir
        with_depot_path([temp_dir]) do
            # Install something with a huge number of Package and Artiface dependencies
            Pkg.add(Pkg.PackageSpec(;name="Gtk", version=v"1.1.2"))
        end
    end

    # Test that the resources we expect to exist are in fact cached on the server.
    # We just test that a few UUIDs and tree hashes exist:
    pkg_uuid_treehashes = [
        # XML2_jll
        "02c8fc9c-b97f-50b9-bbe4-9be30ff0a78a" => "ed5603a695aefe3e9e404fc7b052e02cc72cfab6",
        # Gtk
        "4c0ca9eb-093a-5379-98c5-f87ac0bbbf44" => "ab2676a65345f8813be07675aa657464f98e6704",
        # FixedPointNumbers
        "53c48c17-4a7d-5ca2-90c5-79b7896eea93" => "4aaea64dd0c30ad79037084f8ca2b94348e65eaa",
        # Zlib_jll
        "83775a58-1f1d-513f-b197-d71354ab007a" => "5618a43055eb09377edca21d19d0e99bce24a9c3",
    ]
    for (uuid, treehash) in pkg_uuid_treehashes
        @test isfile(joinpath(cache_dir, "package", uuid, treehash))
    end

    artifact_treehashes = [
        # Adwaita theme
        "17b6682b222ef6ff06805a6c674b00c68ddc8a9c",
        # libgraphite2
        "a40f51fd288579f98e42fd6f15a02a79ef2f148c",
        # libgtk
        "df170e77ddcd59c018c7abe5dddd5a7bcbf8b5eb",
    ]
    for treehash in artifact_treehashes
        @test isfile(joinpath(cache_dir, "artifact", treehash))
    end
end
