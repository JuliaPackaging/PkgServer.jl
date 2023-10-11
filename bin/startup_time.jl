#!/usr/bin/env julia

using HTTP

p = run(setenv(`$(Base.julia_cmd()) --project=$(Base.active_project()) $(@__DIR__)/run_server.jl`, "JULIA_PKG_SERVER" => "http://127.0.0.1:8080"); wait=false)
t_start = time()

try
    while true
        try
            r = HTTP.get("http://localhost:8080/meta"; connect_timeout=1, status_exception=false)
            if r.status == 200
                @info("Successful connection:", duration=time() - t_start)
                break
            end
        catch e
            if (isa(e, Base.IOError) && e.code == -Base.Libc.ECONNREFUSED) ||
                # TODO: Use ExceptionUnwrapping.jl documented API...
               (isa(e, HTTP.ConnectError) && e.error.ex.code == -Base.Libc.ECONNREFUSED)
            else
                @warn(e, typeof(e))
            end
        end
        if (time() - t_start) >= 90
            @error("Timeout!")
            break
        end
        if !Base.process_running(p)
            @error("Server died:")
            @show p
            wait(p)
            break
        end
        print(".")
    end
finally
    kill(p)
    wait(p)
end
