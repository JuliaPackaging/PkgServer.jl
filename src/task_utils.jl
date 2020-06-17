macro try_printerror(ex)
    return quote
        try
            $(esc(ex))
        catch e
            if isa(e, InterruptException)
                rethrow()
            end
            @error(e)
            for (exc, bt) in Base.catch_stack()
                showerror(stdout, exc, bt)
                println()
            end
        end
    end
end
