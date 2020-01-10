#!/bin/bash

BRANCH_NAME="$1"
if [[ -z "${BRANCH_NAME}" ]]; then
    echo "Usage: autoupdate.sh <branch_name>" >&2
    exit 1
fi

rm -rf /tmp/PkgServer.jl
git clone -b "${BRANCH_NAME}" https://github.com/JuliaPackaging/PkgServer.jl /tmp/PkgServer.jl
cd /tmp/PkgServer.jl/deployment
make reload_pkgserver
