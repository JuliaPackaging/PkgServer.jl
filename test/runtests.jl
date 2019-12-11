using PkgServer
using Test
using MbedTLS
include("test_auth.jl")

@testset "PkgServer.jl" begin
    sslconfig = (isfile("cert.pem") && isfile("key.pem")) ? SSLConfig(joinpath(@__DIR__, "cert.pem"), joinpath(@__DIR__, "key.pem")) : nothing
    PkgServer.register_storage_server("https://pkg.julialang.org")
    PkgServer.start("127.0.0.1", 8000; authmodule=TestAuth, sslconfig=sslconfig)
end
