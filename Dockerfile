# Keep in sync with .github/workflows/(ci|pkg-update).yml
FROM julia:1.6
#FROM julia:dev

# This Dockerfile must be built with a context of the top-level PkgServer.jl directory
WORKDIR /app

# We're going to try and make this runnable as any UID, so install packages to /depot
RUN mkdir /depot
ENV JULIA_DEPOT_PATH="/depot"

# While we're trying to debug issues, load in some helpful tools
#RUN apt update && apt install -y gdb procps

# Copy in Project.toml/Manifest.toml, instantiate immediately, so that we don't have to do this
# every time we rebuild, since those files should change relatively slowly.
ADD *.toml /app/
RUN julia --project=/app -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
# /depot/compiled is going to be modified by the user that actually runs this container
RUN chmod 777 -R /depot/compiled
# We can drop this step once we're on Julia 1.6.
# X-ref: https://github.com/JuliaLang/Pkg.jl/issues/2053#issuecomment-701055801
RUN chmod 755 /depot/artifacts/*

# Our default command is to run the pkg server with the bundled `run_server.jl` script
CMD ["julia", "--project=/app", "/app/bin/run_server.jl"]

# Next, copy in full `PkgServer.jl` directory (this is the step that will most often be invalidated)
ADD . /app

# Precompile PkgServer
RUN julia --project=/app -e "using PkgServer"
