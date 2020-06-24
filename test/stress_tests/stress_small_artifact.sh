#!/bin/bash

source common.sh

true_hash=ade2fa0e2f7d895014746470d2cb7348d7852e2c


num_tests=1000
num_procs=100
for idx in $(seq 1 $num_tests); do
    echo "curl -w \"%{http_code} - ${idx}\\n\" -s -L -o /dev/null $(url artifact/${true_hash})"
done | parallel -j${num_procs}

