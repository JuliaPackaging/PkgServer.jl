#!/usr/bin/env julia

clones_dir = "clones"
static_dir = "static"
get_old_package_artifacts = false

import Pkg
import Pkg.TOML
import Pkg.Artifacts: download_artifact, artifact_path

mkpath(clones_dir)
mkpath(static_dir)

function verify_tarball_hash(hash::String, tarball::String)
    local tree_hash
    mktempdir() do tmp_dir
        run(pipeline(`zstdcat $tarball`, `tar -C $tmp_dir -x -`))
        tree_hash = bytes2hex(Pkg.GitTools.tree_hash(tmp_dir))
        chmod(tmp_dir, 0o777, recursive=true)
    end
    tree_hash == hash || error("tree hash mismatch: $hash ≠ $tree_hash")
    return nothing
end

function process_artifact(info::Dict)
    local tree_hash, input_path, output_path
    try
        tree_hash = info["git-tree-sha1"]
        tree_sha1 = Pkg.Types.SHA1(tree_hash)
        output_path = joinpath(static_dir, "artifact", tree_hash)
        isfile(output_path) && return
        downloads = info["download"]
        downloads isa Array || (downloads = [downloads])
        for download in downloads
            url = download["url"]
            hash = download["sha256"]
            download_artifact(tree_sha1, url, hash, verbose=true) && break
        end
        input_path = artifact_path(tree_sha1, honor_overrides=false)
        isdir(input_path) || error("artifact install failed")
    catch err
        @warn err
    end
    mkpath(dirname(output_path))
    paths = String[]
    for (root, dirs, files) in walkdir(input_path)
        path = root != input_path ? relpath(root, input_path) : ""
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
        open(output_path, write=true) do io
            # reproducible tarball options based on
            # http://h2.jaguarpaw.co.uk/posts/reproducible-tar/
            tar_opts = ```
                --format=posix
                --numeric-owner
                --owner=0
                --group=0
                --mode=ugo=rX
                --mtime=1970-01-01
                --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime,delete=mtime
                --no-recursion
            ```
            tar_cmd = `gtar $tar_opts -cf - -C $input_path --null -T $paths_file`
            run(pipeline(tar_cmd, `zstd -9`, io))
        end
    end
    verify_tarball_hash(tree_hash, output_path)
end

registries = Dict{String,String}()

for depot in DEPOT_PATH
    depot_regs = joinpath(depot, "registries")
    isdir(depot_regs) || continue
    for reg_dir in readdir(depot_regs, join=true)
        isdir(reg_dir) || continue
        reg_file = joinpath(reg_dir, "Registry.toml")
        isfile(reg_file) || continue
        reg_data = TOML.parsefile(reg_file)
        # generate registry tarball
        let tree_hash = readchomp(`git -C $reg_dir rev-parse HEAD`)
            uuid = reg_data["uuid"]
            tarball = joinpath(static_dir, "registry", uuid, tree_hash)
            mkpath(dirname(tarball))
            open(tarball, write=true) do io
                git_archive = `git -C $reg_dir archive $tree_hash`
                run(pipeline(git_archive, `zstd -9`, io))
            end
            registries[reg_data["uuid"]] = tree_hash
        end
        for (uuid, info) in reg_data["packages"]
            name = info["name"]
            path = info["path"]
            pkg_dir = joinpath(reg_dir, path)
            pkg_info = TOML.parsefile(joinpath(pkg_dir, "Package.toml"))
            versions = TOML.parsefile(joinpath(pkg_dir, "Versions.toml"))
            # generate archive of each version
            static_pkg_dir = joinpath(static_dir, "package", uuid)
            mkpath(static_pkg_dir)
            updated = false
            for (ver, info) in versions
                tree_hash = info["git-tree-sha1"]
                tarball = joinpath(static_pkg_dir, tree_hash)
                if (new_tarball = !isfile(tarball))
                    clone_dir = joinpath(clones_dir, uuid)
                    try
                        pkg_repo = pkg_info["repo"]
                        if !isdir(clone_dir)
                            run(`git clone --mirror $pkg_repo $clone_dir`)
                        elseif !updated
                            run(`git -C $clone_dir remote update`)
                        end
                        updated = true
                    catch err
                        println(stderr, "Cannot clone $name [$uuid]")
                        break
                    end
                    try
                        open(tarball, write=true) do io
                            git_archive = `git -C $clone_dir archive $tree_hash`
                            run(pipeline(git_archive, `zstd -9`, io))
                        end
                    catch err
                        println(stderr, "Cannot checkout $name [$uuid] @$tree_hash")
                        rm(tarball, force=true)
                        continue
                    end
                    isfile(tarball) || continue
                end
                new_tarball || get_old_package_artifacts || continue
                # look for artifact files
                for path in eachline(pipeline(`zstdcat $tarball`, `gtar -t`))
                    # NOTE: the above can't handle paths with newlines
                    # doesn't seem to be a way to get tar to use \0 instead
                    basename(path) in Pkg.Artifacts.artifact_names || continue
                    extract = pipeline(`zstdcat $tarball`, `gtar -x -O $path`)
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
end

# generate current registries file
open(joinpath(static_dir, "registries"), write=true) do io
    for (uuid, tree_hash) in sort!(collect(registries))
        println(io, "/registry/$uuid/$tree_hash")
    end
end
