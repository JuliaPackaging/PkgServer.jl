#!/usr/bin/env julia

using HTTP, JSON3, Scratch, TimeZones, Dates, Tar, Gzip_jll

# Get list of Pkg servers
pkg_servers = JSON3.read(String(HTTP.get("https://pkg.julialang.org/meta/siblings").body))
#storage_servers = JSON3.read(String(HTTP.get("https://pkg.julialang.org/meta/parents").body))
storage_servers = ["https://us-east.storage.juliahub.com", "https://kr.storage.juliahub.com"]

function update_git_repo(repo_url::AbstractString, repo_path::AbstractString; branch::AbstractString = "master")
    mkpath(repo_path)
    st = stat(joinpath(repo_path,"HEAD"))
    if !isfile(st)
        run(`git clone --mirror $(repo_url) $(repo_path)`)
    end

    # Return the latest fetched treehash
    run(`git -C $(repo_path) fetch --all`)
    return readchomp(`git -C $(repo_path) rev-parse "$(branch)^{tree}"`)
end

# Clone/update General registry
gen_uuid = Base.UUID("23338594-aafe-5451-b93e-139f81909106")
reg_dir = get_scratch!(Base.UUID("eac38ba3-4627-46d4-b1a1-bcb86ba22f8b"), "Registry-General")
latest_treehash = update_git_repo("https://github.com/JuliaRegistries/General", reg_dir)

function commit_for_tree(repo_path, tree)
    p = open(`git -C $(repo_path) log --pretty='%H %T'`; read=true)
    for line in eachline(p.out)
        commit_hash, commit_tree = split(line)[1:2]
        if commit_tree == tree
            return commit_hash
        end
    end
    return nothing
end
function commit_time(repo_path, commit)
    time_str = readchomp(`git -C $(repo_path) show --quiet --pretty='%cI' $(commit)`)
    ZonedDateTime(time_str, "yyyy-mm-ddTHH:MM:SSzzzzz")
end

hash_map = Dict()
function get_general_time(treehash)
    if haskey(hash_map, treehash)
        return hash_map[treehash]
    end

    commit = commit_for_tree(reg_dir, treehash)
    if commit === nothing
        # If we couldn't find this commit, it's probably because the Registry contains an empty directory or something.
        # This causes us to generate a different hash than git would.  We get the git-compatible hash by downloading the
        # registry then using `Tar` to generate a yskip hash:
        local skip_treehash
        mktempdir() do dir
            @info("Commit for treehash $(treehash) could not be found, determining skip treehash...")
            tarball = joinpath(dir, treehash)
            tarball = HTTP.download("https://pkg.julialang.org/registry/$(gen_uuid)/$(treehash)", tarball)
            gzip() do gzip
                p = open(pipeline(`cat $(tarball)`, `gzip -d`), read=true)
                skip_treehash = Tar.tree_hash(p.out; skip_empty=true)
                close(p.in)
                @info("skip_treehash: $(skip_treehash)")
            end
            Base.Filesystem.prepare_for_deletion(dir)
        end

        commit = commit_for_tree(reg_dir, skip_treehash)
        if commit === nothing
            error("Unable to find commit for General hash $(treehash)/$(skip_treehash)")
        end
    end

    hash_map[treehash] = commit_time(reg_dir, commit)
    return hash_map[treehash]
end

latest_time = get_general_time(latest_treehash)
function get_server_registry_lag(server, flavor)
    local registries
    try
        registries = split(String(HTTP.get("$(server)/registries.$(flavor)"; readtimeout=5).body), "\n")
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        @warn("Unable to fetch `/registries.$(flavor)` from $(server)")
        return Inf
    end
    treehash = basename(first(filter(r -> startswith(r, "/registry/$(gen_uuid)/"), registries)))
    time = get_general_time(treehash)
    lag = canonicalize(latest_time - time)

    # I don't like seeing "empty period" so I manually change it to "0 seconds"
    if isempty(lag.periods)
        return Second(0)
    end
    return lag
end

function async_server_responses(servers; flavors=("eager", "conservative"))
    c = Channel(length(servers))
    # One `async` to get all requests running and return immediately 
    @async begin
        # One `sync` so that we can `close()` once everything else is done
        @sync begin
            for server in servers
                # Another `async` so that each server is processed in parallel
                @async begin
                    flavor_lags = Dict{String,Any}()
                    @sync begin
                        for flavor in flavors
                            # Yet another `@async` so that each request to a single server
                            # is done in parallel as well.
                            @async flavor_lags[flavor] = get_server_registry_lag(server, flavor)
                        end
                    end
                    # Once this particular server is done processing, `put!()` its results
                    put!(c, (server, flavor_lags))
                end
            end
        end
        # After the overall `sync`, close to signify we're done
        close(c)
    end
    return c
end

function print_servers(c::Channel)
    while isopen(c) || isready(c)
        try
            server, flavor_lags = take!(c)
            @info(server, (Symbol(string(k, "_lag")) => v for (k, v) in flavor_lags)...)
        catch e
            if isa(e, InvalidStateException) && e.state == :closed
                continue
            end
            rethrow(e)
        end
    end
end

# Get the current registry hashes for each server:
@info("Storage Servers:")
print_servers(async_server_responses(storage_servers))

@info("Pkg Servers:")
print_servers(async_server_responses(pkg_servers))
