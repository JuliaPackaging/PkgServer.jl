using SnoopCompile, HTTP
ENV["PKGSERVER_GENERATING_PRECOMPILE"] = "true"

# Start tasks to hit all sorts of resources that are useful
@async begin
    for res in ["meta", "meta/stats", "meta/siblings", "meta/parents",
                "robots.txt",
                "registries", "registry/23338594-aafe-5451-b93e-139f81909106/e5ed3655ffd697a8ea2a3fdff0cd14022144f497",
                "package/78c3b35d-d492-501b-9361-3d52fe80e533/916b850daad0d46b8c71f65f719c49957e9513ed",
                "artifact/a4e3df8d4997a3352c87cb1b8a8b86ac6b40ddba"]
        while true
            sleep(0.5)
            try
                r = HTTP.get("http://localhost:8000/$(res)")
                if r.status == 200
                    @info("Successfully got a /$(res) response!")
                    break
                end
            catch
            end
        end
    end

    # Once we've got all these goodies, kill the server
    close(PkgServer.config.listen_server)
end

inf_timing = @snoopi tmin=0.001 begin
    using PkgServer

    mktempdir() do root
        try
            PkgServer.start(storage_root=root)
        catch e
            if !isa(e, Base.IOError) || e.code != -Base.Libc.ECONNABORTED
                rethrow(e)
            end
        end
    end
end

pc = SnoopCompile.parcel(inf_timing)
mktempdir() do dir
    SnoopCompile.write(dir, pc)
    cp(joinpath(dir, "precompile_PkgServer.jl"),
       joinpath(@__DIR__, "precompile.jl"); force=true)
end
