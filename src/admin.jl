using Base64: Base64
using Logging: Logging
using URIs: URIs

include("admin_logging.jl")

# ************************************************************************************
# *                                IMPORTANT                                         *
# * The /admin endpoint must only be configured if the server is secured with HTTPS. *
# * PkgServer itself only uses HTTP, so this has to be configured externally with    *
# * e.g. a TLS terminating reverse proxy.                                            *
# *                                IMPORTANT                                         *
# ************************************************************************************
#
# The `/admin` endpoint is enabled by configuring an admin token. The admin token is used as
# the password for the `admin` user with HTTP basic authentication. The token can be any
# string, but it is recommended to generate a long random one. PkgServer only need the
# SHA256 hash of the token. To tell PkgServer about the token use the environment variable
# `JULIA_PKG_SERVER_ADMIN_TOKEN_SHA256`.
#
# The token and the hash can, for example, be setup as with the following commands:
# ```
# openssl rand 32 \
#     | openssl enc -A -base64 \
#     | tee admin_token.secret \
#     | sha256sum - \
#     | cut -d ' ' -f 1 \
#     | echo "JULIA_PKG_SERVER_ADMIN_TOKEN_SHA256=$(cat -)" >> .env
# ```
# This i) generates a 32-byte admin token, ii) encodes it as base64, iii) prints the token
# to the file `admin_token.secret`, iv) hashes the token, and v) outputs the resulting
# environment variable to a `.env` file.

function simple_http_response(http::HTTP.Stream, s::Int, msg::Union{String,Nothing}=nothing)
    HTTP.setstatus(http, s)
    if msg === nothing
        HTTP.setheader(http, "Content-Length" => "0")
        HTTP.startwrite(http)
    else
        HTTP.setheader(http, "Content-Type" => "text/plain")
        HTTP.setheader(http, "Content-Length" => string(sizeof(msg)))
        HTTP.startwrite(http)
        write(http, msg)
    end
    return nothing
end

function invalid_auth(http)
    msg = "Invalid Authorization header, invalid user, or invalid password.\n"
    HTTP.setheader(http, "WWW-Authenticate" => "Basic")
    return simple_http_response(http, 401, msg)
end

# Matches the base64 encoded data in "Basic <base64 data>"
const basic_auth_regex = r"(?<=^Basic )(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{4})$"
const userinfo_regex = r"^(?<username>.+?):(?<token>.+)$"

function handle_admin(http::HTTP.Stream)
    # If no /admin is disabled tell the user
    if config.admin_token_sha256 === nothing
        msg = "The /admin endpoint is disabled for this server " *
              "since no admin token is configured."
        return simple_http_response(http, 404, msg)
    end
    # Check the Authorization header and extract username and token
    auth = HTTP.header(http, "Authorization", "")
    m = match(basic_auth_regex, auth)
    m === nothing && return invalid_auth(http)
    userinfo = String(Base64.base64decode(m.match::AbstractString))
    m = match(userinfo_regex, userinfo)
    m === nothing && return invalid_auth(http)
    # We have a username and token; verify
    if !(m["username"]::AbstractString == "admin" &&
         bytes2hex(SHA.sha256(m["token"]::AbstractString)) == config.admin_token_sha256::String)
        return invalid_auth(http)
    end
    # All good, open sesame!
    return handle_admin_authenticated(http)
end

# If we end up here then the request is authenticated
function handle_admin_authenticated(http::HTTP.Stream)
    method = http.message.method
    uri = URIs.URI(http.message.target)
    if method == "GET" && uri.path == "/admin"
        admin_help = """
        Welcome to the /admin endpoint of the package server.
        The following admin tasks are currently implemented:

        # `GET /admin`

        Fetch this message.

        # `GET /admin/logs`

        Stream log messages until the connection is closed. Debug level log messages are
        enabled with the query parameter `level=debug` (default is `level=info`). Color can
        be disabled with the query parameter `color=false` (default is `color=true`).
        """
        return simple_http_response(http, 200, admin_help)
    elseif method == "GET" && uri.path == "/admin/logs"
        # uri = URIs.URI(http.message.target)
        params = URIs.queryparams(uri)
        color = get(params, "color", "true") == "true"
        req_level = get(params, "level", "info") == "debug" ? Logging.Debug : Logging.Info
        HTTP.setheader(http, "Content-Type" => "text/plain")
        HTTP.startwrite(http)
        attach(ADMIN_LOGGER) do level, message
            level < req_level && return
            write(http, color ? message : remove_colors(message))
        end
    else
        msg = "Unknown /admin endpoint '$(method) $(uri.path)'\n"
        simple_http_response(http, 404, msg)
    end
    return
end
