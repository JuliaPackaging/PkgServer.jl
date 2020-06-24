#!/bin/bash

source common.sh

num_tests=1000
num_procs=100
for idx in $(seq 1 ${num_tests}); do
    fake_uuid=$(randuuid)
    fake_hash=$(randsha1)
    echo "curl -w \"%{http_code} - ${idx}\\n\" -s -L -o /dev/null $(url package/$fake_uuid/$fake_hash)"
    echo "curl -w \"%{http_code} - ${idx}\\n\" -s -L -o /dev/null $(url artifact/$fake_hash)"
done | parallel -j${num_procs}
