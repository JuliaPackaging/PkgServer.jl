#!/bin/bash

BRANCH_NAME="$1"

cd /code
git fetch --all && git checkout "${BRANCH_NAME}" && git reset --hard "origin/${BRANCH_NAME}"
make up
