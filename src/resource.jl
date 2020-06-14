# Utilities to deal with fetching/serving actual Pkg resources

const uuid_re = raw"[0-9a-z]{8}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{12}(?-i)"
const hash_re = raw"[0-9a-f]{40}"
const registry_re = Regex("^/registry/($uuid_re)/($hash_re)\$")
const resource_re = Regex("""
    ^/registry/$uuid_re/$hash_re\$
  | ^/package/$uuid_re/$hash_re\$
  | ^/artifact/$hash_re\$
""", "x")

"""
    get_registries(server)

Interrogate a storage server for a list of registries, match the response against the
registries we are paying attention to, return dict mapping from registry UUID to its
latest treehash.
"""
function get_registries(server::String)
    regs = Dict{String,String}()
    response = HTTP.get("$server/registries")
    for line in eachline(IOBuffer(response.body))
        m = match(registry_re, line)
        if m !== nothing
            uuid, hash = m.captures
            uuid in keys(config.registries) || continue
            regs[uuid] = hash
        else
            @error "invalid response" server=server resource="registries" line=line
        end
    end
    return regs
end

function prune_empty_parents(child, root)
    if !isdir(child)
        return
    end

    root = rstrip(abspath(root), '/')
    child = rstrip(abspath(child), '/')
    last_child = ""

    while child != root && child != last_child
        if !isempty(readdir(child))
            break
        end

        last_child = child
        child = dirname(child)
        rm(last_child; recursive=true)
    end
    return
end


"""
    write_atomic_lru(f::Function, resource::String)

Performs an atomic filesystem write by writing out to a file on the same
filesystem as the given `path`, then `move()`'ing the file to its eventual
destination.  Requires write access to the file and the containing folder.
Currently stages changes at "<path>.tmp.<randstring>".  If the return value
of `f()` is `false` or an exception is raised, the write will be aborted.

Also tracks the file with the global LRU cache as configured in `config.cache`.
"""
function write_atomic_lru(f::Function, resource::String)
    # First, write a temp file into the `temp` directory:
    temp_file = joinpath(config.root, "temp", string(resource[2:end], ".tmp.", randstring()))
    try
        mkpath(dirname(temp_file))
        retval = open(temp_file, "w") do io
            f(temp_file, io)
        end
        if retval !== false
            # Calculate size of the file, notify the cache that we're adding
            # a file of that size, so it may need to shrink the cache:
            new_path = add!(config.cache, resource[2:end], filesize(temp_file))
            mv(temp_file, new_path; force=true)
        end
    catch e
        rethrow(e)
    finally
        rm(temp_file; force=true)
        prune_empty_parents(temp_file, joinpath(config.root, "temp"))
    end
end

function resource_filepath(resource::String)
    # We strip off the leading `/` to pass this into the filecache
    return filepath(config.cache, resource[2:end])
end

"""
    url_exists(url)

Send a `HEAD` request to the specified URL, returns `true` if the response is HTTP 200.
"""
function url_exists(url::AbstractString)
    response = HTTP.request("HEAD", url, status_exception = false)
    response.status == 200
end

"""
    verify_registry_hash(uuid, hash)

Verify that the origin git repository knows about the given registry tree hash.
"""
function verify_registry_hash(uuid::String, hash::String)
    url = Pkg.Operations.get_archive_url_for_version(config.registries[uuid].upstream_url, hash)
    return url === nothing || url_exists(url)
end

function update_registries()
    # collect current registry hashes from servers
    regs = Dict(uuid => Dict{String,Vector{String}}() for uuid in keys(config.registries))
    servers = Dict(uuid => Vector{String}() for uuid in keys(config.registries))
    for server in config.storage_servers
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
            # If the hash already exists locally, skip forward quick
            resource = "/registry/$uuid/$hash"
            if isfile(resource_filepath(resource))
                continue
            end

            # check that the origin repo knows about this hash.  This prevents a
            # rogue storage server from serving malicious registry tarballs.
            if !verify_registry_hash(uuid, hash)
                @debug("rejecting untrusted registry hash", uuid, hash)
                continue
            end

            # try hashes known to fewest servers first, ergo newest
            hash_servers = sort!(hash_info[hash])
            fetch("/registry/$uuid/$hash", servers=hash_servers) !== nothing || continue
            if config.registries[uuid].latest_hash != hash
                @info("new current registry hash", uuid, hash, hash_servers)
                changed = true
            end

            # we've got a new registry hash to serve
            config.registries[uuid].latest_hash = hash
            break
        end
    end
    # write new registry info to file
    registries_path = joinpath(config.root, "static", "registries")
    if changed || !isfile(registries_path)
        new_registries = joinpath(config.root, "temp", "registries.tmp." * randstring())
        open(new_registries, "w") do io
            for uuid in sort!(collect(keys(config.registries)))
                println(io, "/registry/$(uuid)/$(config.registries[uuid].latest_hash)")
            end
        end
        mv(new_registries, registries_path; force=true)
    end
    return changed
end

const fetch_locks = 1024
const FETCH_SEED = rand(UInt)
const FETCH_LOCKS = [ReentrantLock() for _ = 1:fetch_locks]
const FETCH_FAILS = [Set{String}() for _ = 1:fetch_locks]
const FETCH_DICTS = [Dict{String,Event}() for _ = 1:fetch_locks]

function fetch(resource::String; servers=config.storage_servers)
    if hit!(config.cache, lstrip(resource, '/'))
        global cached_hits += 1
        return resource_filepath(resource)
    end

    if isempty(servers)
        @error "fetch called with no servers" resource=resource
        error("fetch called with no servers")
    end

    # make sure only one thread fetches each resource
    i = (hash(resource, FETCH_SEED) % fetch_locks) + 1
    fetch_lock = FETCH_LOCKS[i]
    fetch_fails = FETCH_FAILS[i]
    fetch_dict = FETCH_DICTS[i]

    try
        lock(fetch_lock)

        # check if this has failed to download recently
        if resource in fetch_fails
            @debug("skipping recently failed download", resource)
            return nothing
        end
        # see if any other thread is already downloading
        if resource in keys(fetch_dict)
            # another thread is already downloading this resource
            @debug("waiting for in-progress download", resource)
            fetch_event = fetch_dict[resource]
            wait(fetch_event)
            # Re-fetch; ideally, this result in a successful `hit!()` immediately.
            return fetch(resource; servers=servers)
        end

        fetch_dict[resource] = Event()
    finally
        unlock(fetch_lock)
    end

    # this is the only thread fetching the resource
    success = false
    path = ""
    try
        if length(servers) == 1
            download(servers[1], resource)
        else
            race_lock = ReentrantLock()
            @sync for server in servers
                @spawn begin
                    response = HTTP.head(server * resource, status_exception = false)
                    if response.status == 200
                        # the first thread to get here downloads
                        if trylock(race_lock)
                            download(server, resource)
                            unlock(race_lock)
                        end
                    end
                    # TODO: cancel any hung HEAD requests
                end
            end
        end

        path = resource_filepath(resource)
        success = isfile(path)

        # done at last
        if success
            global fetch_hits += 1
            return path
        end
        return nothing
    finally
        # notify other threads and remove from fetch dict
        lock(fetch_lock) do
            if !success
                push!(fetch_fails, resource)
                @warn "download failed" resource=resource path=path
            end
            notify(pop!(fetch_dict, resource))
        end
    end
end

function forget_failures()
    for i = 1:fetch_locks
        lock(FETCH_LOCKS[i]) do
            empty!(FETCH_FAILS[i])
        end
    end
end

function download(server::String, resource::String)
    @info "downloading resource" server=server resource=resource
    hash = basename(resource)

    write_atomic_lru(resource) do temp_file, file_io
        buffio = Base.BufferStream()
        # Create gzip process to decompress for us, using `gzip()` from `Gzip_jll`
        gzip_proc = gzip(gz -> open(`$gz -d`, read=true, write=true))

        # Create async task to read in from gzip stdout and pipe it straight to `Tar.tree_hash()`
        tar_extract_task = @async Tar.tree_hash(gzip_proc.out; skip_empty=true)

        # Create async task to tee chunks of data from HTTP to file and to gzip
        tee_task = @async begin
            while !eof(buffio)
                chunk = readavailable(buffio)
                write(file_io, chunk)
                write(gzip_proc.in, chunk)
            end
            close(file_io)
            close(gzip_proc.in)
        end

        # Get the response, storing chunks into our BufferStream to get tee'd out
        response = HTTP.get(server * resource,
            status_exception = false,
            response_stream = buffio,
        )

        # Raise warnings about bad HTTP response codes
        if response.status != 200
            @warn "response status $(response.status)"
            return false
        end

        # Wait for the tee task to finish
        wait(tee_task)

        # Fetch the result of the tarball hash check
        calc_hash = fetch(tar_extract_task)

        # If we're given a hash, then check tarball git hash
        if hash != calc_hash
            @warn "resource hash mismatch" server resource hash calc_hash
            return false
        end

        return true
    end
end

function serve_file(
    http::HTTP.Stream,
    path::String,
    content_type::String,
    content_encoding::String;
    buffer::Vector{UInt8} = Vector{UInt8}(undef, 2*1024*1024),
)
    size = filesize(path)
    HTTP.setheader(http, "Content-Length" => string(size))
    HTTP.setheader(http, "Content-Type" => content_type)
    content_encoding == "identity" ||
        HTTP.setheader(http, "Content-Encoding" => content_encoding)
    startwrite(http)

    # Account this hit
    global total_hits += 1

    # Open the path, write it out directly to the HTTP stream in chunks
    open(path) do io
        t = 0
        while !eof(io)
            n = readbytes!(io, buffer)
            t += write(http, view(buffer, 1:n))
        end
        if t != size
            @error "file size mismatch" path stat_size=size actual=t
        end
    end
end
