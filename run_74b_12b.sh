#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export BENCHMARK_PROFILE=74b-12b
exec bash "${script_dir}/run.sh" "$@"
