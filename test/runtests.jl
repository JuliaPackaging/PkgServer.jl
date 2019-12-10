using PkgServer
using Test
include("test_auth.jl")

@testset "PkgServer.jl" begin
    PkgServer.register_storage_server("https://pkg.julialang.org")
    PkgServer.start("127.0.0.1", 8000, authmodule=TestAuth)
end
