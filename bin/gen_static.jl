#!/usr/bin/env julia

using UUIDs
import Pkg.TOML

clones_dir = "clones"
static_dir = "static"

mkpath(clones_dir)
mkpath(static_dir)

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
                isfile(tarball) && continue
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
            end
            isempty(readdir(static_pkg_dir)) && rm(static_pkg_dir)
        end
    end
end
