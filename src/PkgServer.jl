module PkgServer

using HTTP

const temp_dir = "temp"
const cache_dir = "cache"

cache(args...) = joinpath(cache_dir, args...)

const REGISTRIES = [
    "23338594-aafe-5451-b93e-139f81909106",
]
const STORAGE_SERVERS = [
    "http://127.0.0.1:8080",
    "http://127.0.0.1:8081",
]

sort!(REGISTRIES)
sort!(STORAGE_SERVERS)

function current_registries(server::String)
    current = Dict{String,String}()
    response = HTTP.get("$server/registries")
    for line in eachline(IOBuffer(response.body))
        m = match(r"^/registry/([^/]+)/([^/]+)$", line)
        if m !== nothing
            uuid, hash = m.captures
            uuid in REGISTRIES || continue
            current[uuid] = hash
        else
            @error "invalid response" resource="/registries" server=server line=line
        end
    end
    return current
end

# current registry hashes and servers that know about them
const REGISTRY_HASHES = Dict{String,String}()
const REGISTRY_SERVERS = Dict{String,Vector{String}}()

url_exists(url::String) = HTTP.head(url, status_exception = false).status == 200

function update_registries()
    # collect current registry hashes from servers
    regs = Dict(uuid => Dict{String,Vector{String}}() for uuid in REGISTRIES)
    servers = Dict(uuid => Vector{String}() for uuid in REGISTRIES)
    for server in STORAGE_SERVERS
        for (uuid, hash) in current_registries(server)
            push!(get!(regs[uuid], hash, String[]), server)
            push!(servers[uuid], server)
        end
    end
    # for each hash check what other servers know about it
    changed = false
    for (uuid, hash_info) in regs
        isempty(hash_info) && continue # keep serving what we're serving
        for (hash, hash_servers) in hash_info
            for server in servers[uuid]
                server in hash_servers && continue
                url_exists("$server/registry/$uuid/$hash") || continue
                push!(hash_servers, server)
            end
        end
        hashes = sort!(collect(keys(hash_info)))
        sort!(hashes, by = hash -> length(hash_info[hash]))
        for hash in hashes
            # try hashes known to fewest servers first, ergo newest
            servers = hash_info[hash]
            # TODO: fetch("registry", uuid, hash, servers=servers) || continue
            if get(REGISTRY_HASHES, uuid, nothing) != hash
                @info "new registry hash" uuid=uuid hash=hash servers=servers
                changed = true
            end
            REGISTRY_HASHES[uuid] = hash
            REGISTRY_SERVERS[uuid] = servers
            break # we've got a new registry hash to server
        end
    end
    # write new registry info to file
    changed && mktemp(temp_dir) do temp_file, io
        for uuid in REGISTRIES
            hash = REGISTRY_HASHES[uuid]
            println(io, "/registry/$uuid/$hash")
        end
        mv(temp_file, cache("registries"), force=true)
    end
    return changed
end

function run()
    mkpath("temp")
    mkpath("cache")
    update_registries()
    @sync begin
        @async while true
            sleep(1)
            update_registries()
        end
        # handle incoming requests
    end
end

end # module
