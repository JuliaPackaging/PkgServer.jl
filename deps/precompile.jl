# Use
#    @warnpcfail precompile(args...)
# if you want to be warned when a precompile directive fails
macro warnpcfail(ex::Expr)
    modl = __module__
    file = __source__.file === nothing ? "?" : String(__source__.file)
    line = __source__.line
    quote
        $(esc(ex)) || @warn """precompile directive
     $($(Expr(:quote, ex)))
 failed. Please report an issue in $($modl) (after checking for duplicates) or remove this directive.""" _file=$file _line=$line
    end
end


function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    Base.precompile(Tuple{Core.kwftype(typeof(fetch_resource)),NamedTuple{(:servers,), Tuple{Vector{String}}},typeof(fetch_resource),String,String})
    Base.precompile(Tuple{typeof(get_registries),String,String})
    Base.precompile(Tuple{typeof(verify_registry_hash),String,String})
    Base.precompile(Tuple{typeof(wait_first),Task,Vararg{Task}})
    isdefined(PkgServer, Symbol("#22#26")) && Base.precompile(Tuple{getfield(PkgServer, Symbol("#22#26"))})
    isdefined(PkgServer, Symbol("#32#35")) && Base.precompile(Tuple{getfield(PkgServer, Symbol("#32#35"))})
    isdefined(PkgServer, Symbol("#40#42")) && Base.precompile(Tuple{getfield(PkgServer, Symbol("#40#42"))})
    isdefined(PkgServer, Symbol("#60#65")) && Base.precompile(Tuple{getfield(PkgServer, Symbol("#60#65"))})
    isdefined(PkgServer, Symbol("#61#66")) && Base.precompile(Tuple{getfield(PkgServer, Symbol("#61#66"))})
    isdefined(PkgServer, Symbol("#ServerConfig#57#58")) && Base.precompile(Tuple{getfield(PkgServer, Symbol("#ServerConfig#57#58")),InetAddr{IPv4},String,Dict{String, RegistryMeta},Vector{String},Vector{String},Int64,Type{ServerConfig}})
end
