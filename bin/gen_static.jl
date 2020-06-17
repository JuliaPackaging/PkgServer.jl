#!/usr/bin/env julia

const clones_dir = "clones"
const static_dir = "static"
const get_old_package_artifacts = false

# Wait one day before attempting to download bad artifacts/packages again
const blacklist_dir = "blacklist"
const blacklist_timeout = 60*60*24*1

import Dates: DateTime, now
import Pkg
import Pkg.TOML
import Pkg.Artifacts: download_artifact, artifact_path, artifact_names
import Tar
import TranscodingStreams: TranscodingStream
import CodecZlib: GzipCompressor, GzipDecompressor

mkpath(clones_dir)
mkpath(static_dir)
mkpath(blacklist_dir)

compress(io::IO) = TranscodingStream(GzipCompressor(level=9), io)
decompress(io::IO) = TranscodingStream(GzipDecompressor(), io)

function print_exception(e)
    eio = IOBuffer()
    Base.showerror(eio, e, catch_backtrace())
    @error String(take!(eio))
end

function blacklist(args...)
    black_path = joinpath(blacklist_dir, args...)
    mkpath(dirname(black_path))
    touch(black_path)
end

# Returns true if the file has been blacklisted and should not be downloaded
function is_blacklisted(args...)
    black_path = joinpath(blacklist_dir, args...)
    st = stat(black_path)
    if isfile(st) && mtime(st) > time() - blacklist_timeout
        return true
    end
    return false
end

function prune_empty_blacklist_dirs(path)
    if !isdir(path)
        return
    end
    if abspath(path) == blacklist_dir
        return
    end
    if isempty(readdir(path))
        rm(path; force=true)
        prune_empty_blacklist_dirs(dirname(path))
    end
end

function clear_blacklist(args...)
    black_path = joinpath(blacklist_dir, args...)
    if isfile(black_path)
        rm(black_path; force=true)
        prune_empty_blacklist_dirs(dirname(black_path))
    end
end

function make_tarball(
    tarball::AbstractString,
    tree_path::AbstractString,
)
    open(tarball, write=true) do io
        close(Tar.create(tree_path, compress(io)))
    end
    return tarball
end

function create_git_tarball(
    tarball::AbstractString,
    repo_path::AbstractString,
    tree_hash::AbstractString,
)
    # If this download is blacklisted, don't even bother.
    if is_blacklisted(tree_hash)
        return
    end
    mktempdir() do tree_path
        run(`git -C $(repo_path) --work-tree=$(tree_path) checkout -f $(tree_hash) -- .`)
        make_tarball(tarball, tree_path)
        try
            nskip_hash, yskip_hash = verify_tarball_hash(tarball, tree_hash)
            clear_blacklist(tree_hash)

            # If we've been calling it by the wrong hash, make sure to store it at the right name too
            if nskip_hash != tree_hash
                nskip_tarball = joinpath(dirname(tarball), nskip_hash)
                if !isfile(nskip_tarball)
                    cp(tarball, nskip_tarball)
                end
            end
        catch err
            @warn err repo_path tarball tree_path
            ondisk_hash = bytes2hex(Pkg.GitTools.tree_hash(tree_path))
            @warn "verifying on-disk hash" ondisk_hash
            blacklist(tree_hash)
            rm(tarball, force=true)
        end
    end
    return
end

function verify_tarball_hash(
    tarball::AbstractString,
    tree_hash::AbstractString,
)
    nskip_hash = open(io -> Tar.tree_hash(decompress(io)), tarball)
    yskip_hash = open(io -> Tar.tree_hash(decompress(io); skip_empty=true), tarball)
    if nskip_hash != tree_hash && yskip_hash != tree_hash
        error("""
            tree hash mismatch:
            - expected: $tree_hash
            - computed: $nskip_hash/$yskip_hash
        """)
    end
    return nskip_hash, yskip_hash
end

function process_artifact(info::Dict)
    local tree_hash, tree_path, tarball
    try
        tree_hash = info["git-tree-sha1"]
        if is_blacklisted(tree_hash)
            return
        end
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
        if !isdir(tree_path)
            blacklist(tree_hash)
            error("artifact install failed")
        else
            clear_blacklist(tree_hash)
        end
    catch err
        @warn err
        blacklist(tree_hash)
        return
    end
    mkpath(dirname(tarball))
    make_tarball(tarball, tree_path)
    try
        nskip_hash, yskip_hash = verify_tarball_hash(tarball, tree_hash)
        clear_blacklist(tree_hash)

        if nskip_hash != tree_hash
            nskip_tarball = joinpath(dirname(tarball), nskip_hash)
            if !isfile(nskip_tarball)
                cp(tarball, nskip_tarball)
            end
        end
    catch err
        @warn err tree_path=tree_path tarball=tarball
        blacklist(tree_hash)
        rm(tarball, force=true)
    finally
        chmod(tree_path, 0o700, recursive=true)
        rm(tree_path, force=true, recursive=true)
    end
    return
end

registries = Dict{String,String}()

# These functions are very linux-only
function getsid(pid::Cint)
    return ccall(:getsid, Cint, (Cint,), pid)
end
getsid(p::Base.Process) = getsid(getpid(p))

function killpg(pgid::Cint, sig=Base.SIGTERM)
    return ccall(:killpg, Cint, (Cint, Cint), pgid, sig)
end
killpg(p::Base.Process, sig=Base.SIGTERM) = killpg(getsid(p), sig)

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
        run(`git -C $reg_dir pull`)
        let tree_hash = readchomp(`git -C $reg_dir rev-parse 'HEAD^{tree}'`)
            uuid = reg_data["uuid"]
            tarball = joinpath(static_dir, "registry", uuid, tree_hash)
            if !isfile(tarball)
                mkpath(dirname(tarball))
                create_git_tarball(tarball, reg_dir, tree_hash)
            end
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
                   # Run this process detached, so it gets its own process group
                   process = run(detach(`git clone --mirror $pkg_repo $clone_dir`), wait = false)

                   is_clone_failure = false
                   @info "($pc/$total_packages) Cloning in process...", name, pkg_repo
                   while process_running(process)
                       elapsed = (time() - timeout_start)
                       if elapsed > timeout
                           @warn("Terminating cloning $pkg_repo")
                           killpg(process)
                           start_time = time()
                           while process_running(process)
                               @debug "waiting for process to terminate"
                               if time() - start_time > kill_timeout
                                   @debug("Killing $name")
                                   sleep(1)
                                   killpg(process, Base.SIGKILL)
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
                # If this tree_hash is blacklisted, skip it.
                if is_blacklisted(uuid, tree_hash)
                    continue
                end

                tarball = joinpath(static_pkg_dir, tree_hash)
                if (is_new_tarball = !isfile(tarball))
                    pkg_repo = pkg_info["repo"]
                    @label again
                    try create_git_tarball(tarball, clone_dir, tree_hash)
                    catch err
                        @info("create_git_tarball() failed", err)
                        if updated
                            println(stderr, "Cannot checkout $name [$uuid] $tree_hash")
                            blacklist(uuid, tree_hash)
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
                # Clear the blacklist on this treehash
                clear_blacklist(uuid, tree_hash)

                # look for artifact files
                tmp_dir, paths = open(tarball) do io
                    paths = String[]
                    Tar.extract(decompress(io)) do hdr
                        if split(hdr.path, '/')[end] in artifact_names
                            push!(paths, hdr.path)
                            return true
                        else
                            return false
                        end
                    end, paths
                end
                for path in paths
                    sys_path = joinpath(tmp_dir, path)
                    try
                        artifacts = TOML.parse(read(sys_path, String))
                        for (key, val) in artifacts
                            if val isa Dict
                                process_artifact(val)
                            elseif val isa Vector
                                foreach(process_artifact, val)
                            else
                                @warn "invalid artifact file entry: $val" name path
                            end
                        end
                    catch err
                        @warn "error processing artifact file" error=err name path
                    end
                end
                chmod(tmp_dir, 0o700, recursive=true)
                rm(tmp_dir, recursive=true)
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
