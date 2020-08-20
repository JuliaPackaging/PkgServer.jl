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

"""
    tee_task(io_in, io_outs...)

Creates an asynchronous task that reads in from `io_in` in buffer chunks, writing
available bytes out to all elements of `io_outs` as quickly as possible until `io_in` is
closed.  Closes all elements of `io_outs` once that is finished.  Returns the `Task`.
"""
function tee_task(io_in, io_outs...)
    return @async begin
        @try_printerror begin
            total_size = 0
            while !eof(io_in)
                chunk = readavailable(io_in)
                total_size += length(chunk)
                for io_out in io_outs
                    write(io_out, chunk)
                end
            end
            for io_out in io_outs
                close(io_out)
            end
            return total_size
        end
    end
end

"""
    wait_first(args...)

Return the first waitable (Task, Condition, etc...) that becomes ready.
"""
function wait_first(args...)
    if isempty(args)
        return nothing
    end

    c = Channel()
    for arg in args
        @async begin
            wait(arg)
            put!(c, arg)
        end
    end
    return take!(c)
end

function try_open(args...; kwargs...)
    try
        return open(args...; kwargs...)
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
    end
    return nothing
end