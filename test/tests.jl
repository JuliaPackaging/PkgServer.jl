# Server may be sleepy and still waking up; wait until we can ask it for `/registries`
t_start = time()
@info("Waiting for PkgServer liveness")
while true
    # Try to get an HTTP 200 OK on /registries
    response_code = try
        HTTP.get("$(server_url)/registries"; retry = false, readtimeout=1).status
    catch e
        # If it just can't connect, deal with it silently, otherwise rethrow
        if isa(e, HTTP.IOExtras.IOError) && e.e.code in (-Base.Libc.ECONNREFUSED, -Base.Libc.EPIPE, -Base.Libc.ECONNRESET)
            # Return fake status code, this doesn't really matter, just so long as it's not 200
            e.e.code
        else
            rethrow(e)
        end
    end

    if response_code == 200
        break
    end

    # If we've been trying this for more than 20s, error out
    if (time() - t_start) >= 20
        error("Unable to hit testing server at $(server_url)/registries, get HTTP $(response_code)")
    end

    # Sleep a bit between attempts
    sleep(0.2)
end

@testset "Direct HTTP requests" begin
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
        @test registry_treehash == Tar.tree_hash(open(pipeline(`cat $(tarball_path)`, `gzip -d`), read=true))
    end

    # Verify that these files exist within the cache
    @test isfile(joinpath(cache_dir, "..", "static", "registries"))
    @test isfile(joinpath(cache_dir, "registry", registry_uuid, registry_treehash))

    # Next, hit the `/meta` endpoint, ensure that the version it reports matches with what we expect:
    response = HTTP.get("$(server_url)/meta")
    @test response.status == 200
    meta = JSON3.read(String(response.body))
    @test haskey(meta, "pkgserver_version")
    @test meta["pkgserver_version"] == PkgServer.get_pkgserver_version()

    # Ensure that some random URL gets a 404
    @test_throws HTTP.ExceptionRequest.StatusError HTTP.get("$(server_url)/docs")
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
            # Prevent `Pkg.add()` from changing PkgServer.jl's Project.toml
            Pkg.activate(temp_dir)
            # Install something with a huge number of Package and Artifact dependencies
            Pkg.add(Pkg.PackageSpec(;name="Gtk", version=v"1.1.2"))

            # Install something with platform-independent artifacts, so that we can check the hashes
            Pkg.add(Pkg.PackageSpec(;name="DotNET", version=v"0.1.0"))
            Pkg.add(Pkg.PackageSpec(;name="FIGlet", version=v"0.2.1"))
        end
    end

    # Test that the resources we expect to exist are in fact cached on the server.
    # We just test that a few UUIDs and tree hashes exist.  Note we use the exact packages
    # listed above, otherwise we may not know what the treehash actually should be.
    pkg_uuid_treehashes = [
        # Gtk
        "4c0ca9eb-093a-5379-98c5-f87ac0bbbf44" => "ab2676a65345f8813be07675aa657464f98e6704",
        # DotNET
        "5091b313-875f-492b-8fe1-0f0d7d725ad8" => "58259eee27b838bfbf234cbfd043e3f090389f66",
        # FIGlet
        "3064a664-84fe-4d92-92c7-ed492f3d8fae" => "bfc6b52f75b4720581e3e49ae786da6764e65b6a"
    ]
    for (uuid, treehash) in pkg_uuid_treehashes
        @test isfile(joinpath(cache_dir, "package", uuid, treehash))
    end

    artifact_treehashes = [
        # DotNET clrbridge
        "5c005e142ebba033996dcc97b249e9e5ebcbf138",
        # FIGlet fonts
        "125ac0315d68bbb612f8c2189ea83401f73238f0",
    ]
    for treehash in artifact_treehashes
        @test isfile(joinpath(cache_dir, "artifact", treehash))
    end

    # Ensure that, when we hit `/meta` now, the server knows that it has a bunch of packages and artifacts:
    response = HTTP.get("$(server_url)/meta")
    @test response.status == 200
    meta = JSON3.read(String(response.body))
    @test haskey(meta, "julia_version")
    @test VersionNumber(meta["julia_version"]) >= v"1.3"
    @test haskey(meta, "pkgserver_version")
    @test meta["pkgserver_version"] == PkgServer.pkgserver_version
end

@testset "Access Tracking" begin
    # Test that the `/stats` endpoint works as expected
    response = HTTP.get("$(server_url)/stats")
    @test response.status == 200
    stats = JSON3.read(String(response.body))
    @test haskey(stats, "packages_cached")
    @test stats["packages_cached"] >= 70
    @test haskey(stats, "artifacts_cached")
    @test stats["artifacts_cached"] >= 30

    # Find "/registries" endpoint, hit it a couple of times, ensure that the LRU count goes up each time
    figlet_fonts_resource = "artifact/125ac0315d68bbb612f8c2189ea83401f73238f0"
    figlet_fonts_entry = stats["lru"][figlet_fonts_resource]
    @test figlet_fonts_entry["num_accessed"] > 0

    # Now, hit this a couple more times:
    for idx in 1:5
        HTTP.get("$(server_url)/$(figlet_fonts_resource)")
    end

    # Refresh the stats
    response = HTTP.get("$(server_url)/stats")
    @test response.status == 200
    stats = JSON3.read(String(response.body))

    # Ensure that the counter went up, and that the timing has advanced:
    @test stats["lru"][figlet_fonts_resource]["num_accessed"] >= figlet_fonts_entry["num_accessed"] + 5
    @test stats["lru"][figlet_fonts_resource]["last_accessed"] > figlet_fonts_entry["last_accessed"]
end