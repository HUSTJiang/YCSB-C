#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export BENCHMARK_PROFILE=16b-1024b-5000w
exec bash "${script_dir}/run.sh" "$@"
