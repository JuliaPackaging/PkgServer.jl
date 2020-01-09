FROM julia:1.3

# This Dockerfile must be built with a context of the top-level PkgServer.jl directory
WORKDIR /app

# Do initial update so that we at least have a registry cloned, to speed up the instantiate later
RUN ["julia", "-e", "using Pkg; Pkg.update()"]

# Copy in full `PkgServer.jl` directory
ADD . /app

# Tell Julia to instantiate our project
RUN ["julia", "--project=/app", "-e", "using Pkg; Pkg.instantiate()"]

# Our default comamnd is to run the pkg server with the bundled `run_server.jl` script
CMD ["julia", "--project=/app", "/app/bin/run_server.jl"]
