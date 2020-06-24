#!/bin/bash

source common.sh

true_uuid=de9282ab-8554-53be-b2d6-f6c222edabfc
true_hash=75470c0d825076c229ec59e60bd81f83e878bbc4

num_tests=1000
num_procs=100
for idx in $(seq 1 $num_tests); do
    echo "curl -w \"%{http_code} - ${idx}\\n\" -s -L -o /dev/null $(url package/${true_uuid}/${true_hash})"
done | parallel -j${num_procs}

