module PkgServer

using HTTP
using Base.Threads: Event, @spawn

const REGISTRIES = Dict(
    "23338594-aafe-5451-b93e-139f81909106" =>
        "https://github.com/JuliaRegistries/General.git",
)

const STORAGE_SERVERS = [
    "http://127.0.0.1:8080",
    "http://127.0.0.1:8081",
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

const REGISTRY_HASHES = Dict{String,String}()

git_cmd(args::Cmd; dir::Union{String,Nothing}=nothing) =
    dir === nothing ? `git $args` : `git -C $dir $args`
git(args::Cmd; dir::Union{String,Nothing}=nothing) =
    run(pipeline(git_cmd(args, dir=dir), stdout=devnull, stderr=devnull))

function update_registries()
    changed = false
    mkpath("registries")
    for (uuid, repo) in REGISTRIES
        dir = joinpath("registries", uuid)
        if !isdir(dir)
            try git(`clone -q --bare --single-branch --depth=1 $repo $dir`)
            catch err
                @error "Cannot clone registry" uuid=uuid repo=repo error=err
                continue
            end
        else
            try
                git(`remote set-url origin $repo`, dir=dir)
                git(`remote update`, dir=dir)
            catch err
                @error "Cannot update registry" uuid=uuid repo=repo error=err
                continue
            end
        end
        hash = readchomp(git_cmd(`rev-parse 'HEAD^{tree}'`, dir=dir))
        get(REGISTRY_HASHES, uuid, nothing) == hash && continue
        @info "new current registry hash" uuid=uuid hash=hash
        REGISTRY_HASHES[uuid] = hash
        changed = true
    end
    # write new registry info to file
    changed && mktemp("temp") do temp_file, io
        for uuid in keys(REGISTRIES)
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

function download(server::String, resource::String, path::String)
    @info "downloading resource" server=server resource=resource
    mktemp("temp") do temp_file, io
        response = HTTP.get(server * resource, status_exception = false, response_stream = io)
        response.status == 200 && mv(temp_file, path, force=true)
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
        end
    end
end

end # module
