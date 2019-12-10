"""
This defines a module that can be plugged in to PkgServer as an optional authentication layer.

- intended to serve as a test authentication system only.
- reads userid and password from a plaintext file.
- issues access_token and refresh_token after authenticating plaintext userid and password.
- validates access_token
- issues new access_token and refresh_token given a valid refresh_token
"""
module TestAuth

using HTTP
using Random
using Pkg.TOML
using Base64
using Serialization

const token_validity_duration = 60*60*24
function create_access_token(userid; expires_in=token_validity_duration)
    time_now = round(Int, time())
    expires_at = time_now + expires_in
    (expires_at=expires_at, expires_in=expires_in, userid=userid)
end
decode_access_token(access_token_hdr) = deserialize(IOBuffer(base64decode(access_token_hdr)))
function encode_access_token(access_token)
    iob = IOBuffer()
    serialize(iob, access_token)
    base64encode(take!(iob))
end
validate_access_token(access_token) = (access_token.expires_at >= time())

const authdb = ["guest1" "password1" ""; "guest2" "password2" ""]

function do_issue_token(userid, password)
    for idx in 1:length(authdb)
        if authdb[idx,1] == userid
            (authdb[idx,2] == password) || error("invalid password")
            authdb[idx,3] = refreshtok = randstring(32)
            return create_access_token(userid), refreshtok # return access and refresh tokens
        end
    end
    error("invalid userid")
end

function do_refresh_token(refreshtok)
    for idx in 1:length(authdb)
        if authdb[idx,3] == refreshtok
            authdb[idx,3] = refreshtok = randstring(32)
            return create_access_token(authdb[idx,1]), refreshtok # return access and refresh tokens
        end
    end
    error("invalid refresh token")
end

function serve_token(http::HTTP.Stream, access_token, refresh_token, refresh_url)
    TOML.print(http, Dict(
        "access_token" => encode_access_token(access_token),
        "refresh_token" => refresh_token,
        "userid" => access_token.userid,
        "expires_at" => access_token.expires_at,
        "expires_in" => access_token.expires_in,
        "refresh_url" => refresh_url
    ))
end

function extract_token(http::HTTP.Stream)
    auth_header = HTTP.header(http, "Authorization")
    @assert startswith(auth_header, "Bearer ")
    split(auth_header, ' '; limit=2)[2]
end

function handle_authtoken_issue(http::HTTP.Stream, refresh_url)
    try
        body = HTTP.URIs.queryparams(String(HTTP.read(http)))
        access_token, refresh_token = do_issue_token(body["user_name"], body["password"])
        serve_token(http, access_token, refresh_token, refresh_url)
    catch
        HTTP.setstatus(http, 401)
        startwrite(http)
    end
end

function handle_authtoken_refresh(http::HTTP.Stream, refresh_url)
    try
        token = extract_token(http)
        access_token, refresh_token = do_refresh_token(token)
        serve_token(http, access_token, refresh_token, refresh_url)
    catch
        HTTP.setstatus(http, 401)
        startwrite(http)
    end
end

function handle_authenticated(f, http::HTTP.Stream)
    token = extract_token(http)
    access_token = decode_access_token(token)
    if validate_access_token(access_token)
        return f()
    else
        HTTP.setstatus(http, 401)
        startwrite(http)
        true
    end
end

end # module TestAuth
