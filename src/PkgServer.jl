module PkgServer

using Pkg
using HTTP
using Base.Threads: Event, @spawn
using Random
using LibGit2

using Tar
using CodecZlib

decompress(io::IO) = GzipDecompressorStream(io)

include("resource.jl")
include("meta.jl")

function __init__()
    # Set default HTTP useragent
    HTTP.setuseragent!("PkgServer (HTTP.jl)")
end

function start(;host="127.0.0.1", port=8000)
    mkpath("cache")
    update_registries()
    @sync begin
        @spawn while true
            sleep(1)
            try
                forget_failures()
                update_registries()
            catch e
                @error("Registry update error: ", e)
            end
        end
        @info "server listening on $(host):$(port)"
        HTTP.listen(host, port) do http
            resource = http.message.target
            # If the user is asking for `/meta`, generate the requisite JSON object and send it back
            if occursin(meta_re, resource)
                serve_meta(http)
                return
            end

            # If the user asked for soemthing that is an actual resource, send it directly
            if occursin(resource_re, resource)
                path = fetch(resource)
                if path !== nothing
                    serve_file(http, path)
                    return
                end
            end
            HTTP.setstatus(http, 404)
            startwrite(http)
        end
    end
end

end # module
