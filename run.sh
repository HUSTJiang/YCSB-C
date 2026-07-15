#!/bin/bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ycsbc="${YCSBC:-${repo_root}/ycsbc}"
bucket="${BUCKET:-testbucket1-jx}"
region="${REGION:-ap-northeast-1}"

threads="${THREADS:-8}"
record_count="${RECORD_COUNT:-50000000}"
operation_count_override="${OPERATION_COUNT:-}"
workload_names="${WORKLOADS:-a b c d f}"

workload_a_ops="${WORKLOAD_A_OPS:-${operation_count_override:-500000}}"
workload_b_ops="${WORKLOAD_B_OPS:-${operation_count_override:-200000}}"
workload_c_ops="${WORKLOAD_C_OPS:-${operation_count_override:-200000}}"
workload_d_ops="${WORKLOAD_D_OPS:-${operation_count_override:-200000}}"
workload_e_ops="${WORKLOAD_E_OPS:-${operation_count_override:-10000}}"
workload_f_ops="${WORKLOAD_F_OPS:-${operation_count_override:-200000}}"

key_length="${KEY_LENGTH:-74}"
field_length="${FIELD_LENGTH:-12}"
num_levels="${NUM_LEVELS:-7}"
hot_file_level_limit="${HOT_FILE_LEVEL_LIMIT:-1}"
hash_fanout="${HASH_FANOUT:-4}"
write_buffer_size="${WRITE_BUFFER_SIZE:-$((128 * 1024 * 1024))}"
target_file_size_base="${TARGET_FILE_SIZE_BASE:-$((32 * 1024 * 1024))}"
max_background_jobs="${MAX_BACKGROUND_JOBS:-8}"
max_subcompactions="${MAX_SUBCOMPACTIONS:-1}"
block_cache_size="${BLOCK_CACHE_SIZE:-0}"
bloom_bits="${BLOOM_BITS:-10}"

run_id="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
data_root="${DATA_ROOT:-/localdata/benchmark}"
wal_root="${WAL_ROOT:-/nvmedata/benchmark}"
result_dir="${RESULT_ROOT:-${repo_root}/results}/${run_id}"

rocksdb_cloud_path="${data_root}/${run_id}/ycsb-rocksdb-cloud"
rocksdb_cloud_wal="${wal_root}/${run_id}/ycsb-rocksdb-cloud"
lsm_hash_path="${data_root}/${run_id}/ycsb-lsm-hash"
lsm_hash_wal="${wal_root}/${run_id}/ycsb-lsm-hash"

if [[ ! -x "${ycsbc}" ]]; then
  echo "YCSB-C binary is not executable: ${ycsbc}" >&2
  exit 1
fi
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be exported." >&2
  exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required for S3 validation and cleanup." >&2
  exit 1
fi
if (( record_count % threads != 0 )); then
  echo "RECORD_COUNT must be divisible by THREADS." >&2
  exit 1
fi

read -r -a workloads <<<"${workload_names}"
declare -A workload_ops=(
  [a]="${workload_a_ops}"
  [b]="${workload_b_ops}"
  [c]="${workload_c_ops}"
  [d]="${workload_d_ops}"
  [e]="${workload_e_ops}"
  [f]="${workload_f_ops}"
)
for workload in "${workloads[@]}"; do
  if [[ ! "${workload}" =~ ^[a-f]$ ]]; then
    echo "Unsupported workload '${workload}'; expected letters a through f." >&2
    exit 1
  fi
  workload_operation_count="${workload_ops[${workload}]}"
  if (( workload_operation_count % threads != 0 )); then
    echo "Operation count for workload ${workload} must be divisible by THREADS." >&2
    exit 1
  fi
done

mkdir -p "${result_dir}" \
  "${rocksdb_cloud_path}" "${rocksdb_cloud_wal}" \
  "${lsm_hash_path}" "${lsm_hash_wal}"

{
  echo "run_id=${run_id}"
  echo "threads=${threads}"
  echo "record_count=${record_count}"
  echo "workloads=${workload_names}"
  for workload in "${workloads[@]}"; do
    echo "workload_${workload}_operations=${workload_ops[${workload}]}"
  done
  echo "key_length=${key_length}"
  echo "field_length=${field_length}"
  echo "num_levels=${num_levels}"
  echo "hot_file_level_limit=${hot_file_level_limit}"
  echo "hash_fanout=${hash_fanout}"
  echo "write_buffer_size=${write_buffer_size}"
  echo "target_file_size_base=${target_file_size_base}"
  echo "max_background_jobs=${max_background_jobs}"
  echo "max_subcompactions=${max_subcompactions}"
  echo "block_cache_size=${block_cache_size}"
  echo "bloom_bits=${bloom_bits}"
  echo "bucket=${bucket}"
  echo "region=${region}"
  echo "result_dir=${result_dir}"
} | tee "${result_dir}/config.log"

dstat_pid=""
iostat_pid=""

stop_monitors() {
  if [[ -n "${dstat_pid}" ]]; then
    kill "${dstat_pid}" 2>/dev/null || true
    wait "${dstat_pid}" 2>/dev/null || true
    dstat_pid=""
  fi
  if [[ -n "${iostat_pid}" ]]; then
    kill "${iostat_pid}" 2>/dev/null || true
    wait "${iostat_pid}" 2>/dev/null || true
    iostat_pid=""
  fi
}
trap stop_monitors EXIT INT TERM

start_monitors() {
  local phase=$1

  if command -v dstat >/dev/null 2>&1; then
    dstat -n 1 >"${result_dir}/${phase}-network.log" 2>&1 &
    dstat_pid=$!
  fi
  if command -v iostat >/dev/null 2>&1 &&
     [[ -e "${IO_DEVICE:-/dev/nvme1n1p1}" ]]; then
    iostat -dx 1 "${IO_DEVICE:-/dev/nvme1n1p1}" \
      >"${result_dir}/${phase}-io.log" 2>&1 &
    iostat_pid=$!
  fi
}

empty_bucket() {
  local context=$1
  local remaining

  echo "Emptying S3 bucket ${bucket}: ${context}"
  aws s3 rm "s3://${bucket}/" --recursive --only-show-errors \
    --region "${region}"
  remaining=$(aws s3api list-objects-v2 \
    --bucket "${bucket}" \
    --max-keys 1 \
    --query 'KeyCount' \
    --output text \
    --region "${region}")
  if [[ "${remaining}" != "0" ]]; then
    echo "ERROR: bucket ${bucket} still contains objects after ${context}." >&2
    aws s3 ls "s3://${bucket}/" --recursive --region "${region}" >&2 || true
    return 1
  fi
}

run_ycsb_phase() {
  local case_name=$1
  local phase_name=$2
  local db_path=$3
  local wal_path=$4
  local fanout=$5
  local workload_file=$6
  local load=$7
  local run=$8
  local insert_start=$9
  local phase_operation_count=${10}
  local log_file="${result_dir}/${case_name}-${phase_name}.log"

  echo "Starting ${case_name}: ${phase_name}"
  start_monitors "${case_name}-${phase_name}"
  if ! "${ycsbc}" \
      -db rocksdb \
      -dbpath "${db_path}" \
      -threads "${threads}" \
      -P "${workload_file}" \
      -load "${load}" \
      -run "${run}" \
      -dboption 1 \
      -dbstatistics true \
      -dbwaitforbalance true \
      -p "recordcount=${record_count}" \
      -p "operationcount=${phase_operation_count}" \
      -p "insertstart=${insert_start}" \
      -p "insertorder=ordered" \
      -p "fieldcount=1" \
      -p "fieldlength=${field_length}" \
      -p "keylength=${key_length}" \
      -p "rawvalues=true" \
      -p "cloud_bucket=${bucket}" \
      -p "cloud_region=${region}" \
      -p "cloud_object_path=${db_path}" \
      -p "wal_dir=${wal_path}" \
      -p "num_levels=${num_levels}" \
      -p "hot_file_level_limit=${hot_file_level_limit}" \
      -p "hash_fanout=${fanout}" \
      -p "write_buffer_size=${write_buffer_size}" \
      -p "target_file_size_base=${target_file_size_base}" \
      -p "max_background_jobs=${max_background_jobs}" \
      -p "max_subcompactions=${max_subcompactions}" \
      -p "block_cache_size=${block_cache_size}" \
      -p "bloom_bits=${bloom_bits}" \
      -p "use_direct_reads=true" \
      -p "use_direct_io_for_flush_and_compaction=true" \
      -p "report_bg_io_stats=true" \
      >"${log_file}" 2>&1; then
    stop_monitors
    echo "ERROR: ${case_name} ${phase_name} failed; see ${log_file}" >&2
    return 1
  fi
  stop_monitors
}

cleanup_case() {
  local case_name=$1
  local db_path=$2
  local wal_path=$3

  aws s3 ls "s3://${bucket}/${db_path#/}/" --recursive --region "${region}" \
    >"${result_dir}/${case_name}-s3.log"
  aws s3 ls "s3://${bucket}/" --recursive --region "${region}" \
    >"${result_dir}/${case_name}-s3-all.log"
  find "${db_path}" -type f -printf '%P\t%s bytes\n' | sort \
    >"${result_dir}/${case_name}-local-files.log"
  if [[ -f "${db_path}/LOG" ]]; then
    cp "${db_path}/LOG" "${result_dir}/${case_name}-LOG"
  fi

  rm -rf -- "${db_path}" "${wal_path}"
  empty_bucket "${case_name} completed"
}

run_case() {
  local case_name=$1
  local db_path=$2
  local wal_path=$3
  local fanout=$4
  local workload

  run_ycsb_phase "${case_name}" load "${db_path}" "${wal_path}" \
    "${fanout}" "${repo_root}/workloads/workloada.spec" true false 0 \
    "${workload_ops[a]}"

  for workload in "${workloads[@]}"; do
    run_ycsb_phase "${case_name}" "workload-${workload}" \
      "${db_path}" "${wal_path}" "${fanout}" \
      "${repo_root}/workloads/workload${workload}.spec" false true \
      "${record_count}" "${workload_ops[${workload}]}"
  done

  cleanup_case "${case_name}" "${db_path}" "${wal_path}"
}

# This bucket is dedicated to the benchmark. Clear leftovers before the first DB.
empty_bucket "pre-run cleanup"

run_case rocksdb-cloud "${rocksdb_cloud_path}" "${rocksdb_cloud_wal}" 0
run_case lsm-hash "${lsm_hash_path}" "${lsm_hash_wal}" "${hash_fanout}"

grep -hE '^(loading records:|all operation records:)' \
  "${result_dir}"/*.log >"${result_dir}/summary.log" || true

stop_monitors
trap - EXIT INT TERM
echo "All YCSB tests completed. Results: ${result_dir}"
