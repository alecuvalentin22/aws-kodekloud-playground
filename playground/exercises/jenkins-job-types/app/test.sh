#!/bin/sh
# The whole "test suite" of the tiny app. Exit 0 = pass.
set -eu
out=$(sh ./greet.sh Ada demo)
if [ "$out" != "hello Ada from demo" ]; then
  echo "FAIL: greet.sh printed '$out'"
  exit 1
fi
echo "1 test passed"
