FROM julia:1.3

# This Dockerfile must be built with a context of the top-level PkgServer.jl directory
WORKDIR /app

# Copy in Project.toml/Manifest.toml, instantiate immediately, so that we don't have to do this
# every time we rebuild, since those files should change relatively slowly.
ADD *.toml /app/
RUN ["julia", "--project=/app", "-e", "using Pkg; Pkg.instantiate(); Pkg.precompile()"]

# Our default comamnd is to run the pkg server with the bundled `run_server.jl` script
CMD ["julia", "--project=/app", "/app/bin/run_server.jl"]

# Next, copy in full `PkgServer.jl` directory (this is the step that will most often be invalidated)
ADD . /app
