import Logging, LoggingExtras, URIs

# The /admin endpoint is enabled by setting ${JULIA_PKG_SERVER_ADMIN_TOKEN} to
# something non-empty. This acts as the password for the admin user used for
# HTTP basic auth. **This should *only* be enabled if the server is secured
# with HTTPS.**
#
# The token can be any string, but it is recommended to use a server-unique
# long random string of characters and not a classical password, for example
# the output of
#
#     openssl rand -base64 48
#
# Authenticated requests will thus have the header
#
#     Authorization: Basic <credentials>
#
# where <credentials> are Base64 encoded concatenation of the username (admin)
# and the admin token, i.e.
#
#     base64encode("admin:" * token)
#
# We precompute the SHA512 hash of this value and throw away the original token
# from ENV. The hashed value is our "password database".
function hashed_basic_auth_header()
    if (token = get(ENV, "JULIA_PKG_SERVER_ADMIN_TOKEN", ""); !isempty(token))
        basic_auth_header = Base64.base64encode("admin:" * token)
        hashed_basic_auth_header = bytes2hex(SHA.sha512(basic_auth_header))
        # delete!(ENV, "JULIA_PKG_SERVER_ADMIN_TOKEN")
        return hashed_basic_auth_header
    end
    return nothing
end

function simple_http_response(http::HTTP.Stream, s::Int, msg::Union{String,Nothing}=nothing)
    HTTP.setstatus(http, s)
    if msg === nothing
        HTTP.setheader(http, "Content-Length" => "0")
        HTTP.startwrite(http)
    else
        HTTP.setheader(http, "Content-Type" => "text/plain")
        HTTP.setheader(http, "Content-Length" => string(sizeof(msg)))
        HTTP.startwrite(http)
        HTTP.write(http, msg)
    end
    return nothing
end

const admin_lock = ReentrantLock()

function handle_admin(http::HTTP.Stream)
    return @lock admin_lock handle_admin_locked(http)
end

# Matches the base64 encoded data in "Basic <base64 data>"
const basic_auth_regex = r"(?<=^Basic )(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{4})$"

function handle_admin_locked(http::HTTP.Stream)
    # If no admin token set on start, tell the user
    if config.hashed_basic_auth_header === nothing
        msg = "The /admin endpoint is disabled, please configure the " *
              "'JULIA_PKG_SERVER_ADMIN_TOKEN' variable to enable it.\n"
        return simple_http_response(http, 200, msg)
    end
    # Check authorization
    auth = HTTP.header(http, "Authorization", "")
    m = match(basic_auth_regex, auth)
    if m !== nothing && bytes2hex(SHA.sha512(m.match)) == config.hashed_basic_auth_header
        # All good, handle the request
        return handle_admin_authenticated(http)
    end
    return simple_http_response(http, 403)
end

original_logger = nothing

# If we end up here then the request is authenticated
function handle_admin_authenticated(http::HTTP.Stream)
    method = http.message.method
    uri = URIs.URI(http.message.target)
    if uri.path == "/admin" && method == "GET"
        @info "get help"
        admin_help = """
        Welcome to the /admin endpoint of the package server.
        The following admin tasks are currently implemented:

        # `GET /admin`

        Fetch this message.

        # `GET /admin/logging`

        Return the current logging state.

        # `POST /admin/logging`

        Change the logging state (enabling/disabling debug logging).
        **Body parameters**
         - `enable_debug` (required): `true` to enable, and `false` to disable,
           debug logging.
        """
        return simple_http_response(http, 200, admin_help)
    elseif uri.path == "/admin/logging" && method == "GET"
        @debug "getting logging state"
        data = Dict("enable_debug" => original_logger !== nothing)
        return serve_json(http, data)
    elseif uri.path == "/admin/logging" && method == "POST"
        @debug "setting logging state"
        body = JSON3.read(http)
        if get(body, "enable_debug", nothing) == true
            if original_logger === nothing
                # Wrap original logger in a TeeLogger together with a logger that let's
                # through debug-level messages
                debug_logger = LoggingExtras.TeeLogger(
                    LoggingExtras.TransformerLogger(
                        # Since this logger accept all messages, not just debug, we prepend
                        # [admin] to make it easier to filter visually and programatically
                        log -> merge(log, (; message = "[admin] " * log.message)),
                        Logging.SimpleLogger(stderr, Logging.BelowMinLevel),
                    ),
                    Logging.global_logger(),
                )
                global original_logger = Logging.global_logger(debug_logger)
            end
            return simple_http_response(http, 200)
        elseif get(body, "enable_debug", nothing) == false
            # Disable the extra debug logger by resetting the original logger
            if original_logger !== nothing
                Logging.global_logger(original_logger)
                global original_logger = nothing
            end
            return simple_http_response(http, 200)
        else
            # TODO: Better error handling overall
            return simple_http_response(http, 400)
        end
    else
        msg = "Unknown /admin endpoint.\n"
        simple_http_response(http, 404, msg)
    end
    return
end
