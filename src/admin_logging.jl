using Logging: Logging
using LoggingExtras: LoggingExtras

# TODO: Perhaps all of this can be upstreamed to LoggingExtras as an AttachableLogger.

mutable struct AdminLogger <: Logging.AbstractLogger
    const lock::ReentrantLock
    const active_clients::Base.IdSet{Channel{Tuple{Logging.LogLevel, String}}}
    @atomic n_clients::Int
    function AdminLogger()
        return new(ReentrantLock(), Base.IdSet{Channel{Tuple{Logging.LogLevel, String}}}(), 0)
    end
end

const ADMIN_LOGGER = AdminLogger()

# Level filtering is done later in the pipeline
Logging.min_enabled_level(::AdminLogger) = Logging.BelowMinLevel

Logging.catch_exceptions(::AdminLogger) = true

function root_module(m::Module)
    while m !== parentmodule(m)
        m = parentmodule(m)
    end
    return m
end

# Only log if we have clients and if the source module is not HTTP
function Logging.shouldlog(admin_logger::AdminLogger, _, mod, _...)
    return @atomic(admin_logger.n_clients) > 0 && root_module(mod) != HTTP
end

# For every log message we stringify once (using ConsoleLogger's format for
# now) and then send to all the active clients
function Logging.handle_message(admin_logger::AdminLogger, level, args...; kwargs...)
    @atomic(admin_logger.n_clients) == 0 && return
    # Stringify the message using the ConsoleLogger's format
    io = IOBuffer()
    ioc = IOContext(io, :color => true)
    tmp_logger = Logging.ConsoleLogger(ioc, Logging.BelowMinLevel)
    Logging.handle_message(tmp_logger, level, args...; kwargs...)
    msg = String(take!(io))
    # The work for each client is just a put! on an infinitely sized channel which
    # should i) be quick (holding the lock is fine) and ii) be non-blocking
    @lock admin_logger.lock begin
        for client in admin_logger.active_clients
            try
                put!(client, (level, msg))
            catch
                # The only failure mode above should be if the channel is closed already
                @assert !isopen(client)
                # close(client)
            end
        end
    end
    return nothing
end

# Used to store the previous global logging configuration when installing the
# admin logger so that it can be restored later
PREVIOUS_GLOBAL_LOGGER::Union{Nothing, Logging.AbstractLogger} = nothing

function attach(f::Function, admin_logger::AdminLogger)
    # Create the client channel with the callback function `f`
    taskref = Ref{Task}()
    client = Channel{Tuple{Logging.LogLevel, String}}(Inf; taskref=taskref) do c
        for (level, msg) in c
            try
                f(level, msg)
            catch _
                # TODO: Only swallow write errors?
                close(c)
            end
        end
    end
    # Take the lock and attach the client to the logger
    @lock admin_logger.lock begin
        # Make sure the logger is installed in the global logger. We could leave it
        # installed at all times, but since we expect to have clients attached quite rarely
        # we do this little dance to not cause any overhead during normal operation.
        if PREVIOUS_GLOBAL_LOGGER === nothing
            global PREVIOUS_GLOBAL_LOGGER = Logging.global_logger(
                LoggingExtras.TeeLogger(admin_logger, Logging.global_logger()),
            )
        end
        # Add the client
        push!(admin_logger.active_clients, client)
        @atomic admin_logger.n_clients = length(admin_logger.active_clients)
    end
    # Block until the client is finished.
    wait(taskref[])
    @assert !isopen(client)
    # Client has disconnected
    @lock admin_logger.lock begin
        # Detach this (and any other closed) clients from the logger
        filter!(isopen, admin_logger.active_clients)
        @atomic admin_logger.n_clients = length(admin_logger.active_clients)
        # If there are no active clients the admin logger can be uninstalled
        if @atomic(admin_logger.n_clients) == 0
            @assert PREVIOUS_GLOBAL_LOGGER !== nothing
            Logging.global_logger(PREVIOUS_GLOBAL_LOGGER)
            global PREVIOUS_GLOBAL_LOGGER = nothing
        end
    end
    return
end

function remove_colors(str::String)
    io = IOBuffer(; sizehint = sizeof(str))
    for x in Iterators.filter(x -> x isa Char, Iterators.map(last, Base.ANSIIterator(str)))
        write(io, x)
    end
    return String(take!(io))
end
