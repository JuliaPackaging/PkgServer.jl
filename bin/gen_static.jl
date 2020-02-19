#!/usr/bin/env julia

using Dates

const clones_dir = "clones"
const static_dir = "static"
const get_old_package_artifacts = false

import Pkg
import Pkg.TOML
import Pkg.Artifacts: download_artifact, artifact_path
import LibGit2

# TODO: ensure all registries are git clones
Pkg.update()

mkpath(clones_dir)
mkpath(static_dir)

const tar_opts = ```
    --format=posix
    --numeric-owner
    --owner=0
    --group=0
    --mode=go-w,+X
    --mtime=1970-01-01
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime,delete=mtime
    --no-recursion
```
# reproducible tarball options based on
# http://h2.jaguarpaw.co.uk/posts/reproducible-tar/

const compress = `gzip -9`
const decompress = `gzcat`

function print_exception(e)
    eio = IOBuffer()
    Base.showerror(eio, e, catch_backtrace())
    @error String(take!(eio))
end

function make_tarball(
    tarball::AbstractString,
    tree_path::AbstractString,
)
    paths = String[]
    for (root, dirs, files) in walkdir(tree_path)
        path = root != tree_path ? relpath(root, tree_path) : ""
        for file in [dirs; files]
            push!(paths, joinpath(path, file))
        end
    end
    sort!(paths)
    mktemp() do paths_file, io
        for path in paths
            print(io, "$path\0")
        end
        close(io)
        open(tarball, write=true) do io
            tar_cmd = `gtar $tar_opts -cf - -C $tree_path --null -T $paths_file`
            run(pipeline(tar_cmd, compress, io))
        end
    end
    return
end

function create_git_tarball(
    tarball::AbstractString,
    repo_path::AbstractString,
    tree_hash::AbstractString,
)
    repo = LibGit2.GitRepo(repo_path)
    tree = LibGit2.GitObject(repo, tree_hash)
    mktempdir() do tree_path
        opts = LibGit2.CheckoutOptions(
            checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
            target_directory = Base.unsafe_convert(Cstring, tree_path)
        )
        LibGit2.checkout_tree(repo, tree, options=opts)
        make_tarball(tarball, tree_path)
        try
            verify_tarball_hash(tarball, tree_hash)
        catch err
            @warn err repo_path=repo_path tarball=tarball
            rm(tarball, force=true)
        end
    end
    return
end

function verify_tarball_hash(
    tarball::AbstractString,
    tree_hash::AbstractString,
)
    local hash
    mktempdir() do tmp_dir
        run(pipeline(`$decompress $tarball`, `tar -C $tmp_dir -x`))
        hash = bytes2hex(Pkg.GitTools.tree_hash(tmp_dir))
        chmod(tmp_dir, 0o777, recursive=true)
    end
    hash == tree_hash || error("""
        tree hash mismatch:
        - expected: $tree_hash
        - computed: $hash
        """)
    return
end

function process_artifact(info::Dict)
    local tree_hash, tree_path, tarball
    try
        tree_hash = info["git-tree-sha1"]
        tree_sha1 = Pkg.Types.SHA1(tree_hash)
        tarball = joinpath(static_dir, "artifact", tree_hash)
        isfile(tarball) && return
        haskey(info, "download") || return
        downloads = info["download"]
        downloads isa Array || (downloads = [downloads])
        for download in downloads
            url = download["url"]
            hash = download["sha256"]
            download_artifact(tree_sha1, url, hash, verbose=true) && break
        end
        tree_path = artifact_path(tree_sha1, honor_overrides=false)
        isdir(tree_path) || error("artifact install failed")
    catch err
        @warn err
    end
    mkpath(dirname(tarball))
    make_tarball(tarball, tree_path)
    try
        verify_tarball_hash(tarball, tree_hash)
    catch err
        @warn err tree_path=tree_path tarball=tarball
        rm(tarball, force=true)
    end
    return
end

registries = Dict{String,String}()

for depot in DEPOT_PATH
    depot_regs = joinpath(depot, "registries")
    isdir(depot_regs) || continue
    @info "Begin Sync...", string(DateTime(now()))
    for reg_dir in readdir(depot_regs, join=true)
        isdir(reg_dir) || continue
        reg_file = joinpath(reg_dir, "Registry.toml")
        isfile(reg_file) || continue
        reg_data = TOML.parsefile(reg_file)
        # generate registry tarball
        let tree_hash = readchomp(`git -C $reg_dir rev-parse 'HEAD^{tree}'`)
            uuid = reg_data["uuid"]
            tarball = joinpath(static_dir, "registry", uuid, tree_hash)
            mkpath(dirname(tarball))
            create_git_tarball(tarball, reg_dir, tree_hash)
            registries[reg_data["uuid"]] = tree_hash
        end
        total_packages = length(reg_data["packages"])
        @debug "Packages to be processed:", total_packages
        pc = 0
        for (uuid, info) in reg_data["packages"]
            pc += 1
            @debug "processing $(info["name"]) .. $pc/$total_packages"
            name = info["name"]
            path = info["path"]
            pkg_dir = joinpath(reg_dir, path)
            pkg_info = TOML.parsefile(joinpath(pkg_dir, "Package.toml"))
            versions = TOML.parsefile(joinpath(pkg_dir, "Versions.toml"))
            pkg_repo = pkg_info["repo"]
            # generate archive of each version
            static_pkg_dir = joinpath(static_dir, "package", uuid)
            isdir(static_pkg_dir) || mkpath(static_pkg_dir)
            clone_dir = joinpath(clones_dir, uuid)
            updated = false
            if !isdir(clone_dir)
                try
                   timeout_start = time()
                   timeout = 720
                   kill_timeout = 60
                   process = run(`git clone --mirror $pkg_repo $clone_dir`, wait = false)
                   is_clone_failure = false
                   @info "($pc/$total_packages) Cloning in process...", name, pkg_repo
                   while process_running(process)
                       elapsed = (time() - timeout_start)
                       if elapsed > timeout
                           @warn("Terminating cloning $pkg_repo")
                           kill(process)
                           start_time = time()
                           while process_running(process)
                               @debug "waiting for process to terminate"
                               if time() - start_time > kill_timeout
                                   @debug("Killing $name")
                                   sleep(1)
                                   kill(process, Base.SIGKILL)
                                   is_clone_failure = true
                               end
                           end
                           @warn "Unable to clone $pkg_repo: skipping"
                           is_clone_failure = true
                       end
                       sleep(1)
                   end
                   is_clone_failure && continue
                catch err
                    print_exception(err)
                    println(stderr, "Cannot clone $name [$uuid]")
                    break
                end
                updated = true
            end
            for (ver, info) in versions
                tree_hash = info["git-tree-sha1"]
                tarball = joinpath(static_pkg_dir, tree_hash)
                if (is_new_tarball = !isfile(tarball))
                    pkg_repo = pkg_info["repo"]
                    @label again
                    try create_git_tarball(tarball, clone_dir, tree_hash)
                    catch err
                        if updated
                            println(stderr, "Cannot checkout $name [$uuid] $tree_hash")
                            rm(tarball, force=true)
                            continue
                        end
                        updated = true
                        try run(`git -C $clone_dir remote update`)
                        catch err
                            println(stderr, "Cannot update $name [$uuid]")
                            continue
                        end
                        @goto again
                    end
                    isfile(tarball) || continue
                end
                is_new_tarball || get_old_package_artifacts || continue
                # look for artifact files
                for path in eachline(pipeline(`$decompress $tarball`, `gtar -t`))
                    # NOTE: the above can't handle paths with newlines
                    # doesn't seem to be a way to get tar to use \0 instead
                    basename(path) in Pkg.Artifacts.artifact_names || continue
                    extract = pipeline(`$decompress $tarball`, `gtar -x -O $path`)
                    artifacts = TOML.parse(read(extract, String))
                    for (key, val) in artifacts
                        if val isa Dict
                            process_artifact(val)
                        elseif val isa Vector
                            foreach(process_artifact, val)
                        else
                            @warn "invalid artifact file entry: $val"
                        end
                    end
                end
            end
            isempty(readdir(static_pkg_dir)) && rm(static_pkg_dir)
        end
    end
    @debug "Sync completed", string(DateTime(now()))
end

# generate current registries file
open(joinpath(static_dir, "registries"), write=true) do io
    for (uuid, tree_hash) in sort!(collect(registries))
        println(io, "/registry/$uuid/$tree_hash")
    end
end
