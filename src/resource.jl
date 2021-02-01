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
function get_registries(server::AbstractString)
    regs = Dict{String,String}()
    response = HTTP.get("$server/registries", status_exception = false)
    if response.status != 200
        @error("Failure to fetch /registries", server, response.status)
        return regs
    end
    for line in eachline(IOBuffer(response.body))
        m = match(registry_re, line)
        if m !== nothing
            uuid, hash = m.captures
            uuid in keys(config.registries) || continue
            regs[uuid] = hash
        else
            @error("invalid response", server, resource="registries", line)
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
    write_atomic_lru(f::Function, resource::AbstractString)

Performs an atomic filesystem write by writing out to a file on the same
filesystem as the given `path`, then `move()`'ing the file to its eventual
destination.  Requires write access to the file and the containing folder.
Currently stages changes at "<path>.tmp.<randstring>".  If the return value
of `f()` is `false` or an exception is raised, the write will be aborted.

Also tracks the file with the global LRU cache as configured in `config.cache`.
"""
function write_atomic_lru(f::Function, resource::AbstractString)
    temp_file = temp_resource_filepath(resource)
    try
        # First, write a temp file into the `temp` directory:
        mkpath(dirname(temp_file))
        retval = open(temp_file, "w") do io
            f(temp_file, io)
        end
        if retval !== false
            # Calculate size of the file, notify the cache that we're adding
            # a file of that size, so it may need to shrink the cache:
            new_path = add!(config.cache, resource[2:end], filesize(temp_file))
            @info("Moving", temp_file, new_path, filesize(temp_file))
            mv(temp_file, new_path; force=true)
        end
        return retval
    catch e
        rethrow(e)
    finally
        @info("Deleting and pruning", temp_file)
        if isfile(temp_file)
            rm(temp_file; force=true)
        end
        #prune_empty_parents(temp_file, joinpath(config.root, "temp"))
    end
end

function resource_filepath(resource::AbstractString)
    # We strip off the leading `/` to pass this into the filecache
    return filepath(config.cache, resource[2:end])
end

function temp_resource_filepath(resource::AbstractString)
    return joinpath(config.root, "temp", string(resource[2:end], ".inprogress"))
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
function verify_registry_hash(uuid::AbstractString, hash::AbstractString)
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
        # Sort hashes by number of servers that know about it, to
        # serve the "newest" hashes first.
        hashes = collect(keys(hash_info))
        sort!(hashes, by = hash -> length(hash_info[hash]))
        for hash in hashes
            resource = "/registry/$uuid/$hash"

            # If this hash is not already on the filesystem, we might need to fetch it!
            hash_servers = sort!(hash_info[hash])
            if !isfile(resource_filepath(resource))
                # check that the origin repo knows about this hash.  This prevents a
                # rogue storage server from serving malicious registry tarballs.
                if !verify_registry_hash(uuid, hash)
                    @debug("rejecting untrusted registry hash", uuid, hash)
                    continue
                end

                # Try to fetch from our servers, but if something goes wrong, continue
                dl_state = fetch_resource(resource, servers=hash_servers)
                if dl_state === nothing
                    continue
                end
                # If nothing went wrong, pause and wait for the download to finish.
                wait(dl_state.dl_task)
            end

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
        mkpath(dirname(new_registries))
        open(new_registries, "w") do io
            for uuid in sort!(collect(keys(config.registries)))
                println(io, "/registry/$(uuid)/$(config.registries[uuid].latest_hash)")
            end
        end
        mkpath(dirname(registries_path))
        mv(new_registries, registries_path; force=true)
    end
    return changed
end

"""
    NUM_FETCH_STATES

We shard our fetch state across `NUM_FETCH_STATES` different buckets, so that we can
theoretically have `M` different requests going at once for different resources, but the
same resource gets blocked on multiple simultaneous cache misses.  In practice we'll have
many accidental collisions before truly saturating, but that's fine since the happy path
(a cache hit) doesn't even need to enter this block, so unnecessary blocking should
hopefully be quite rare.  In general, we can caluclate the probability of accidental
blocking by taking the average number of simultaneous cache misses `M` and the number of
buckets `N` and plugging them into the birthday problem formula:

    prob_blocked(N, M) = 1 - factorial(big(N))/(big(N)^M * factorial(big(N - M)))

Therefore, making the blind assertion that we, on average, suffer two simultaneous
cache misses, a bucket number of 128 yields an accidental blocking chance of 0.7%.
That sounds pretty good to me, so 128 it is.
"""
const NUM_FETCH_STATES = 128

struct DownloadState
    # The actual resource (from which we can get the path via `resource_filepath()` and `temp_resource_filepath()`
    resource::String
    # Full length of the resource (obtained via the HEAD request to the storage server)
    content_length::Int
    # Task that is doing the downloading
    dl_task::Task
end

struct FetchState
    lock::ReentrantLock
    failed::Set{String}
    inprogress::Dict{String,DownloadState}

    FetchState() = new(ReentrantLock(), Set{String}(), Dict{String,DownloadState}())
end
const FETCH_STATES = [FetchState() for idx in 1:NUM_FETCH_STATES]

function with_fetch_state(f::Function, resource::AbstractString)
    state_idx = mod1(hash(resource), NUM_FETCH_STATES)
    state = FETCH_STATES[state_idx]
    lock(state.lock) do
        return f(state)
    end
end

"""
    select_server(resource, servers)

Given a resource and a list of storage servers, return the storage server that responds
most quickly to a HEAD request for that storage server, as well as the HEAD response
itself so that metadata such as the content-length of the resource can be inspected.
"""
function select_server(resource::AbstractString, servers::Vector{<:AbstractString}; timeout = 5, retries = 2)
    function head_req(server, resource)
        @try_printerror begin
            response = HTTP.head(
                string(server, resource);
                status_exception = false,
                timeout = timeout,
                retries = retries,
            )
            return server, response
        end
    end
    # Launch one task per server, performing a HEAD request
    tasks = [@spawn head_req(server, resource) for server in servers]

    # Wait for the first Task that gives us an HTTP 200 OK, returning that server.
    # If none have it, we return `nothing`. :(
    while !isempty(tasks)
        next_task = wait_first(tasks...)
        deleteat!(tasks, findfirst(t -> t == next_task, tasks))
        @try_printerror begin
            server, http_response = fetch(next_task)
            if http_response.status == 200
                return server, http_response
            end
        end
    end
    return nothing, nothing
end

function content_length(resp::HTTP.Messages.Response)
    for h in resp.headers
        if lowercase(h[1]) == "content-length"
            return parse(Int, h[2])
        end
    end
    return nothing
end

function resource_is_downloading(resource::AbstractString)
    with_fetch_state(resource) do state
        if resource in keys(state.inprogress)
            return state.inprogress[resource]
        end
    end
end

"""
    fetch_resource(resource::AbstractString; servers=config.storage_servers)

Reaches out to the list of storage servers, requesting `resource` from the server that
responds with an HTTP 200 OK the fastest.  Downloads on an asynchronous task stored as a
part of the `DownloadState` structure that this function returns.  Failures to download
are recorded and future downloads of that same resource will be skipped, until
`forget_failures()` is called.  The `DownloadState` object contains within it enough
information to still serve a resource as it is being downloaded in the background task.
"""
function fetch_resource(resource::AbstractString; servers::Vector{String}=config.storage_servers)
    if isempty(servers)
        @error("fetch called with no servers", resource)
        error("fetch called with no servers")
    end

    # with_fetch_state() will wait for a lock
    with_fetch_state(resource) do state
        # check if this has failed to download recently
        if resource in state.failed
            @debug("skipping recently failed download", resource)
            return nothing
        end

        # check if this resource is being downloaded already
        if resource in keys(state.inprogress)
            @debug("detected in-progress download", resource)
            return state.inprogress[resource]
        end

        # If not, let's figure out which storage server we're going to download from:
        server, response = select_server(resource, servers)
        if response === nothing
            @debug("no upstream server", resource, servers)
            return nothing
        end

        # Launch download process in a separate task:
        dl_task = @async begin
            success = download(server, resource, content_length(response))
            lock(state.lock) do
                if success
                    global fetch_hits += 1
                else
                    # If the download failed, wait a bit before retrying
                    push!(state.failed, resource)
                end
                # Once downloading is done, remove this resource from the list of inprogress downloads
                delete!(state.inprogress, resource)
            end
        end

        # Generate a DownloadState, map that to this resource
        state.inprogress[resource] = DownloadState(resource, content_length(response), dl_task)
        return state.inprogress[resource]
    end
end

function forget_failures()
    for idx in 1:NUM_FETCH_STATES
        lock(FETCH_STATES[idx].lock) do
            empty!(FETCH_STATES[idx].failed)
        end
    end
end


"""
    stream_file(io_in::IO, start_byte::Int, length::Int, dl_task::Task, io_out::IO)

Streams from a file `io_in` to an output `IO` object `io_out`.  Reads from `io_in` until
the requested `length` bytes are read, or the download task `dl_task` is finished and it
is certain no more bytes are going to be stored within the file.  Returns the total
number of bytes read from `io_in` and output into `io_out`.
"""
function stream_file(io_in::IO, start_byte::Int, length::Int, dl_task::Task, io_out::IO,
                     buffer::Vector{UInt8} = Vector{UInt8}(undef, 2*1024*1024))
    # Because this file may be an incomplete stream, we need to wait until our start byte
    # is ready, so we `sleep` in a loop while we attempt to `seek()`
    seek(io_in, start_byte)
    while position(io_in) != start_byte
        sleep(0.01)
        seek(io_in, start_byte)
    end

    transmitted = 0
    while transmitted < length
        # See JuliaLang/julia#36300, can be optimized later to only read r bytes
        # r = min(length(buffer), content_length - t)
        # n = readbytes!(io, buffer, r)
        n = readbytes!(io_in, buffer)

        # If we got nothing, either the file is prematurely truncated, or we're still downloading it somewhere.
        if n == 0
            # If we're still streaming, just sleep for a bit before trying again.
            if !istaskdone(dl_task)
                sleep(0.001)
            else
                # Otherwise, break out, something went wrong. :/
                @error("dl_task abnormal termination!")
                fetch(dl_task)
                break
            end
        else
            try
                transmitted += write(io_out, view(buffer, 1:min(n, length - transmitted)))
            catch e
                # If the client disappears, just silently early-exit
                if isa(e, Base.IOError) && e.code in (-Base.Libc.EPIPE, -Base.Libc.ECONNRESET)
                    return transmitted
                end
                rethrow(e)
            end
        end
    end
    return transmitted
end

function download(server::AbstractString, resource::AbstractString, content_length::Int)
    @info "downloading resource" server=server resource=resource
    t_start = time()
    hash = basename(resource)

    write_atomic_lru(resource) do temp_file, file_io
        # We've got a moderately complex flow of data here.  We manage it all using
        # asynchronous tasks and processes.  In summary, we need to download the given
        # resource, decompress it, and determine its tree hash.  Complicating this is the
        # fact that the tree hash could be an older tree hash that skipped empty
        # directories, so we need to tree hash it twice.  And we want to do this in a
        # streaming fashion, so as to minimize latency for the user.
        #
        # We therefore:
        #   - Stream HTTP request into `file_io`, as fast as it can go.  This is to
        #     ensure that when we cache miss, we can `cat` out that file to the user
        #     as quickly as possible.
        #   - `cat` `file_io` into `gzip_proc`, to decompress it for live tree hashing,
        #     while `serve_file()` can stream `file_io` out to the client.
        #   - tee `gzip_proc` into two separate `tar_task_*` tasks, to compute the skip-
        #     empty and non-skip-empty hashes simultaneously.
        #   - If either of the hashes match, we keep the file.  If it was originally
        #     identified by the `skip_empty` version of the hash, store it under both.

        # Backing buffers for `tee` nodes
        #tar_skip_buffio = BufferStream(16*1024*1024)
        #tar_noskip_buffio = BufferStream(16*1024*1024)

        # Create gzip process to decompress for us, using `gzip()` from `Gzip_jll`
        #gzip_proc = gzip(gz -> open(`$gz -d`, read=true, write=true))

        # Create tee node splitting gzip -> (skip, noskip)
        #tar_tee_task = tee_task(gzip_proc.out, tar_skip_buffio, tar_noskip_buffio)

        # Create two tasks to read in the gzip output and do in-tar tree hashing.
        #tar_skip_task = @async Tar.tree_hash(tar_skip_buffio; skip_empty=true)
        #tar_noskip_task = @async Tar.tree_hash(tar_noskip_buffio; skip_empty=false)

        # Initiate the HTTP request, and start the data flowing into the file
        http_task = @async HTTP.get(server * resource,
            status_exception = false,
            response_stream = file_io,
        )

        # Read data back out from that file into the decompressor
        # file_read_task = @async begin
        #     open(temp_file, read=true) do read_file_io
        #         written = stream_file(read_file_io, 0, content_length, http_task, gzip_proc.in)
        #         global payload_bytes_received += written
        #     end
        #     close(gzip_proc.in)
        # end

        # Raise warnings about bad HTTP response codes
        response = fetch(http_task)
        if response.status != 200
            @warn "response status $(response.status)"
            return false
        end
        global payload_bytes_received += filesize(temp_file)
        @info "download complete" server=server resource=resource elapsed=(time() - t_start)

        # Wait for the file read and tee tasks to finish
        #wait(file_read_task)
        #wait(tar_tee_task)

        # Fetch the result of the tarball hash check
        # calc_skip_hash = fetch(tar_skip_task)
        # calc_noskip_hash = fetch(tar_noskip_task)

        # If nothing matches, freak out.
        # if hash != calc_skip_hash && hash != calc_noskip_hash
        #     @warn "resource hash mismatch" server resource hash calc_skip_hash calc_noskip_hash
        #     return false
        # end

        # If calc_skip_hash matches, then store the file under the true hash as well.
        # if hash != calc_noskip_hash && hash == calc_skip_hash
        #     @warn "archaic skip hash detected" resource hash calc_noskip_hash

        #     noskip_resource = joinpath(basename(resource), calc_noskip_hash)
        #     write_atomic_lru(noskip_resource) do noskip_temp_file, noskip_file_io
        #         close(noskip_file_io)
        #         rm(noskip_temp_file)
        #         cp(temp_file, noskip_temp_file)
        #     end
        # end

        return true
    end
end

function serve_file(http::HTTP.Stream,
                    io::IO,
                    content_type::AbstractString,
                    content_encoding::AbstractString = "identity";
                    buffer::Vector{UInt8} = Vector{UInt8}(undef, 2*1024*1024),
                    content_length = filesize(io),
                    dl_task::Task = @async(nothing))
    # Initialize range parameters
    startbyte = 0
    stopbyte = content_length - 1

    # Support single byte ranges
    range_string = HTTP.header(http, "Range")
    if !isempty(range_string)
        # Look for the following patterns: "bytes=a-b", "bytes=a-", and "bytes=-b".
        # Empty captures will fail tryparse and then be replaced with the correct endpoints.
        m = match(r"^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$", range_string)
        if m === nothing
            @error "unsupported HTTP Range request, ignoring" range_string
        else
            # Special-case an input like `-2047`, since we need to count from the back in that case
            local requested_startbyte, requested_stopbyte
            if isempty(m[1])
                requested_startbyte = min(content_length - something(tryparse(Int, m[2]), 0), content_length - 1)
                requested_stopbyte = content_length - 1
            else
                requested_startbyte = max(something(tryparse(Int, m[1]), startbyte), startbyte)
                requested_stopbyte = min(something(tryparse(Int, m[2]), stopbyte), stopbyte)
            end
            if requested_stopbyte - requested_startbyte >= 0
                startbyte = requested_startbyte
                stopbyte = requested_stopbyte
                HTTP.setstatus(http, 206) # Partial Content
                HTTP.setheader(http, "Content-Range" => "bytes $(startbyte)-$(stopbyte)/$(content_length)")
                content_length = stopbyte - startbyte + 1
            else
                HTTP.setstatus(http, 416)
                HTTP.write(http, "Invalid computed range $(requested_startbyte)-$(requested_stopbyte)")
                return
            end
        end
    end

    HTTP.setheader(http, "Content-Length" => string(content_length))
    HTTP.setheader(http, "Accept-Ranges" => "bytes")
    HTTP.setheader(http, "Content-Type" => content_type)
    if content_encoding != "identity"
        HTTP.setheader(http, "Content-Encoding" => content_encoding)
    end
    startwrite(http)

    # Account this hit
    global total_hits += 1

    # Only write content if the method is `GET` (e.g. `HEAD` requests get the above headers)
    if http.message.method == "GET"
        transmitted = stream_file(io, startbyte, content_length, dl_task, http, buffer)
        global payload_bytes_transmitted += transmitted
        if transmitted != content_length
            @error("file size mismatch", content_length, actual=transmitted)
        end
    end
end
