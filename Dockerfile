FROM julia:1.3

# This Dockerfile must be built with a context of the top-level PkgServer.jl directory
WORKDIR /app

# We're going to try and make this runnable as any UID, so install packages to /depot
RUN mkdir /depot
ENV JULIA_DEPOT_PATH="/depot"

# Copy in Project.toml/Manifest.toml, instantiate immediately, so that we don't have to do this
# every time we rebuild, since those files should change relatively slowly.
ADD *.toml /app/
RUN julia --project=/app -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
RUN chmod 777 -R /depot/compiled

# Our default command is to run the pkg server with the bundled `run_server.jl` script
CMD ["julia", "--project=/app", "/app/bin/run_server.jl"]

# Next, copy in full `PkgServer.jl` directory (this is the step that will most often be invalidated)
ADD . /app
