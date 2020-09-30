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
reg_dir = get_scratch!("Registry-General", Base.UUID("eac38ba3-4627-46d4-b1a1-bcb86ba22f8b"))
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
    @show time_str
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
            prepare_for_deletion(dir)
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
function get_server_registry_lag(server)
    local registries
    try
        registries = split(String(HTTP.get("$(server)/registries").body), "\n")
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        @warn("Unable to fetch `/registries` from $(server)")
    end
    treehash = basename(first(filter(r -> startswith(r, "/registry/$(gen_uuid)/"), registries)))
    time = get_general_time(treehash)
    return latest_time - time
end


# Get the current registry hash for each server:
@info("Storage Servers:")
for server in storage_servers
    @info(server, lag=get_server_registry_lag(server))
end

@info("Pkg Servers:")
for server in pkg_servers
    @info(server, lag=get_server_registry_lag(server))
end
