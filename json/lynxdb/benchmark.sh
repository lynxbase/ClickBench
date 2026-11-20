#!/bin/bash
# The queries are PPL, not SQL.
export BENCH_QUERIES_FILE="queries.ppl"
exec ../lib/benchmark-common.sh "$@"
