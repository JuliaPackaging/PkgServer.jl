#!/bin/bash

source common.sh

true_hash=d69cdbc9a382494e9e4d7ac7093266fc9be65aa8


num_tests=1000
num_procs=100
for idx in $(seq 1 $num_tests); do
    echo "curl -w \"%{http_code} - ${idx}\\n\" -s -L -o /dev/null $(url artifact/${true_hash})"
done | parallel -j${num_procs}
