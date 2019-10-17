module PkgServer

using Pkg
using HTTP
using Base.Threads: Event, @spawn

HTTP.setuseragent!("PkgServer.jl/HTTP.jl")

const REGISTRIES = Dict(
    "23338594-aafe-5451-b93e-139f81909106" =>
        "https://github.com/JuliaRegistries/General",
)
const STORAGE_SERVERS = [
    "http://127.0.0.1:8080",
    # "http://127.0.0.1:8081",
]
sort!(STORAGE_SERVERS)

const uuid_re = raw"[0-9a-z]{8}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{12}(?-i)"
const hash_re = raw"[0-9a-f]{40}"
const registry_re = Regex("^/registry/($uuid_re)/($hash_re)\$")
const resource_re = Regex("""
    ^/registries\$
  | ^/registry/$uuid_re/$hash_re\$
  | ^/package/$uuid_re/$hash_re\$
  | ^/artifact/$hash_re\$
""", "x")
const hash_part_re = Regex("/($hash_re)\$")

function get_registries(server::String)
    regs = Dict{String,String}()
    response = HTTP.get("$server/registries")
    for line in eachline(IOBuffer(response.body))
        m = match(registry_re, line)
        if m !== nothing
            uuid, hash = m.captures
            uuid in keys(REGISTRIES) || continue
            regs[uuid] = hash
        else
            @error "invalid response" server=server resource="/registries" line=line
        end
    end
    return regs
end

function url_exists(url::String)
    response = HTTP.request("HEAD", url, status_exception = false)
    response.status == 200
end

function verify_registry_hash(uuid::String, hash::String)
    isfile(joinpath("cache", "registry", uuid, hash)) && return true
    url = Pkg.Operations.get_archive_url_for_version(REGISTRIES[uuid], hash)
    return url === nothing || url_exists(url)
end

# current registry hashes and servers that know about them
const REGISTRY_HASHES = Dict{String,String}()
const REGISTRY_SERVERS = Dict{String,Vector{String}}()

function update_registries()
    # collect current registry hashes from servers
    regs = Dict(uuid => Dict{String,Vector{String}}() for uuid in keys(REGISTRIES))
    servers = Dict(uuid => Vector{String}() for uuid in keys(REGISTRIES))
    for server in STORAGE_SERVERS
        for (uuid, hash) in get_registries(server)
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
            # first check if the origin repo knows about this hash
            verify_registry_hash(uuid, hash) || continue
            # try hashes known to fewest servers first, ergo newest
            servers = sort!(hash_info[hash])
            fetch("/registry/$uuid/$hash", servers=servers) !== nothing || continue
            if get(REGISTRY_HASHES, uuid, nothing) != hash
                @info "new current registry hash" uuid=uuid hash=hash servers=servers
                changed = true
            end
            REGISTRY_HASHES[uuid] = hash
            REGISTRY_SERVERS[uuid] = servers
            break # we've got a new registry hash to server
        end
    end
    # write new registry info to file
    changed && mktemp("temp") do temp_file, io
        for uuid in sort!(collect(keys(REGISTRIES)))
            hash = REGISTRY_HASHES[uuid]
            println(io, "/registry/$uuid/$hash")
        end
        mv(temp_file, joinpath("cache", "registries"), force=true)
    end
    return changed
end

const fetch_locks = 1024
const FETCH_SEED = rand(UInt)
const FETCH_LOCKS = [ReentrantLock() for _ = 1:fetch_locks]
const FETCH_FAILS = [Set{String}() for _ = 1:fetch_locks]
const FETCH_DICTS = [Dict{String,Event}() for _ = 1:fetch_locks]

function fetch(resource::String; servers=STORAGE_SERVERS)
    path = "cache" * resource
    isfile(path) && return path
    isempty(servers) && throw(@error "fetch called with no servers" resource=resource)
    # make sure only one thread fetches path
    i = (hash(path, FETCH_SEED) % fetch_locks) + 1
    fetch_lock = FETCH_LOCKS[i]
    lock(fetch_lock)
    # check if this has failed to download recently
    fetch_fails = FETCH_FAILS[i]
    if resource in fetch_fails
        @debug "skipping recently failed download" resource=resource
        unlock(fetch_lock)
        return nothing
    end
    # see if any other thread is already downloading
    fetch_dict = FETCH_DICTS[i]
    if path in keys(fetch_dict)
        # another thread is already downloading path
        @debug "waiting for in-progress download" resource=resource
        fetch_event = fetch_dict[path]
        unlock(fetch_lock)
        wait(fetch_event)
        # TODO: try again if path doesn't exist?
        return ispath(path) ? path : nothing
    end
    fetch_dict[path] = Event()
    unlock(fetch_lock)
    # this is the only thread fetching path
    mkpath(dirname(path))
    if length(servers) == 1
        download(servers[1], resource, path)
    else
        race_lock = ReentrantLock()
        @sync for server in servers
            @spawn begin
                response = HTTP.head(server * resource, status_exception = false)
                if response.status == 200
                    # the first thread to get here downloads
                    if trylock(race_lock)
                        download(server, resource, path)
                        unlock(race_lock)
                    end
                end
                # TODO: cancel any hung HEAD requests
            end
        end
    end
    success = isfile(path)
    success || @warn "download failed" resource=resource
    # notify other threads and remove from fetch dict
    lock(fetch_lock)
    success || push!(fetch_fails, resource)
    notify(pop!(fetch_dict, path))
    unlock(fetch_lock)
    # done at last
    return success ? path : nothing
end

function forget_failures()
    for i = 1:fetch_locks
        fetch_lock = FETCH_LOCKS[i]
        lock(fetch_lock)
        empty!(FETCH_FAILS[i])
        unlock(fetch_lock)
    end
end

function tarball_git_hash(tarball::String)
    local tree_hash
    mktempdir() do tmp_dir
        run(`tar -C $tmp_dir -zxf $tarball`)
        tree_hash = bytes2hex(Pkg.GitTools.tree_hash(tmp_dir))
        chmod(tmp_dir, 0o777, recursive=true)
    end
    return tree_hash
end

function download(server::String, resource::String, path::String)
    @info "downloading resource" server=server resource=resource
    hash = let m = match(hash_part_re, resource)
        m !== nothing ? m.captures[1] : nothing
    end
    mktemp("temp") do temp_file, io
        response = HTTP.get(
            status_exception = false,
            response_stream = io,
            server * resource,
        )
        close(io)
        response.status == 200 || return
        hash === nothing && return
        tree_hash = tarball_git_hash(temp_file)
        if hash == tree_hash
            mv(temp_file, path, force=true)
        else
            @error "resource hash mismatch" server=server resource=resource hash=tree_hash
        end
    end
end

function serve_file(http::HTTP.Stream, path::String)
    open(path) do io
        data = read(io, String)
        write(http, data)
    end
end

function start()
    mkpath("temp")
    mkpath("cache")
    update_registries()
    @sync begin
        @spawn while true
            sleep(1)
            forget_failures()
            update_registries()
        end
        @info "server listening"
        HTTP.listen("127.0.0.1", 8000) do http
            resource = http.message.target
            if occursin(resource_re, resource)
                path = fetch(resource)
                if path !== nothing
                    startwrite(http)
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
