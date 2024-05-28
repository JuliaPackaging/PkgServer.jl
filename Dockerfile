# Keep in sync with .github/workflows/(ci|pkg-update).yml
FROM julia:1.10
#FROM julia:dev

# This Dockerfile must be built with a context of the top-level PkgServer.jl directory
WORKDIR /app

# We're going to try and make this runnable as any UID, so install packages to /depot
RUN mkdir /depot
ENV JULIA_DEPOT_PATH="/depot"

# Make sure the image can be used on any x86_64 machine by setting JULIA_CPU_TARGET
# to the same value used by the generic julia binaries, see
# https://github.com/JuliaCI/julia-buildkite/blob/4b6932992f7985af71fc3f73af77abf4d25bd146/utilities/build_envs.sh#L23-L31
ENV JULIA_CPU_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"

# While we're trying to debug issues, load in some helpful tools
#RUN apt update && apt install -y gdb procps

# Copy in Project.toml/Manifest.toml, instantiate immediately, so that we don't have to do this
# every time we rebuild, since those files should change relatively slowly.
ADD *.toml /app/
RUN julia --project=/app -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"

# Our default command is to run the pkg server with the bundled `run_server.jl` script
CMD ["julia", "--project=/app", "/app/bin/run_server.jl"]

# Next, copy in full `PkgServer.jl` directory (this is the step that will most often be invalidated)
ADD . /app

# Precompile PkgServer
RUN julia --project=/app -e "using PkgServer"
