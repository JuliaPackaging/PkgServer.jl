using Pkg: TOML
using SHA

# Not resource serving, but other interesting dynamic things that the PkgServer can do.
const artifact_toml_re = Regex("""^(/artifact/$hash_re)/([^/]+)\$""")

function serve_artifact_toml(http::HTTP.Stream,
                             artifact_path::AbstractString,
                             artifact_name::AbstractString)
    artifact_tree_hash = basename(artifact_path)
    artifact_sha256_hash = bytes2hex(open(io -> SHA.sha256(io), artifact_path))
    # build a TOML dict to serialize and send out:
    toml = Dict(
        artifact_name => Dict(
            "git-tree-sha1" => artifact_tree_hash,
            "download" => [Dict(
                "sha256" => artifact_sha256_hash,
                "url" => joinpath(get_pkgserver_url(), "artifact", artifact_tree_hash),
            )]
        )
    )
    io = IOBuffer()
    TOML.print(io, toml)
    toml_string = String(take!(io))

    HTTP.setheader(http, "Content-Length" => string(length(toml_string)))
    HTTP.setheader(http, "Content-Type" => "application/toml")
    HTTP.setheader(http, "Content-Disposition" => "attachment; filename=Artifacts.toml")
    startwrite(http)
    return write(http, toml_string)
end