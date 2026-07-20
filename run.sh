#!/bin/bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ycsbc="${YCSBC:-${repo_root}/ycsbc}"
bucket="${BUCKET:-testbucket1-jx}"
region="${REGION:-ap-northeast-1}"

benchmark_profile="${BENCHMARK_PROFILE:-16b-1024b-5000w}"
case "${benchmark_profile}" in
  74b-12b)
    profile_record_count=50000000
    profile_workload_a_ops=500000
    profile_workload_b_ops=200000
    profile_workload_c_ops=200000
    profile_workload_d_ops=200000
    profile_workload_e_ops=10000
    profile_workload_f_ops=200000
    profile_key_length=74
    profile_field_length=12
    ;;
  16b-1024b-1000w)
    profile_record_count=10000000
    profile_workload_a_ops=500000
    profile_workload_b_ops=100000
    profile_workload_c_ops=100000
    profile_workload_d_ops=100000
    profile_workload_e_ops=10000
    profile_workload_f_ops=100000
    profile_key_length=16
    profile_field_length=1024
    ;;
  16b-1024b-5000w)
    profile_record_count=50000000
    profile_workload_a_ops=5000000
    profile_workload_b_ops=1000000
    profile_workload_c_ops=1000000
    profile_workload_d_ops=1000000
    profile_workload_e_ops=1000000
    profile_workload_f_ops=1000000
    profile_key_length=16
    profile_field_length=1024
    ;;
  *)
    echo "Unknown BENCHMARK_PROFILE '${benchmark_profile}'." >&2
    echo "Expected: 74b-12b, 16b-1024b-1000w, or 16b-1024b-5000w." >&2
    exit 1
    ;;
esac

threads="${THREADS:-8}"
record_count="${RECORD_COUNT:-${profile_record_count}}"
operation_count_override="${OPERATION_COUNT:-}"
workload_names="${WORKLOADS:-a b c d f}"

workload_a_ops="${WORKLOAD_A_OPS:-${operation_count_override:-${profile_workload_a_ops}}}"
workload_b_ops="${WORKLOAD_B_OPS:-${operation_count_override:-${profile_workload_b_ops}}}"
workload_c_ops="${WORKLOAD_C_OPS:-${operation_count_override:-${profile_workload_c_ops}}}"
workload_d_ops="${WORKLOAD_D_OPS:-${operation_count_override:-${profile_workload_d_ops}}}"
workload_e_ops="${WORKLOAD_E_OPS:-${operation_count_override:-${profile_workload_e_ops}}}"
workload_f_ops="${WORKLOAD_F_OPS:-${operation_count_override:-${profile_workload_f_ops}}}"

key_length="${KEY_LENGTH:-${profile_key_length}}"
field_length="${FIELD_LENGTH:-${profile_field_length}}"
num_levels="${NUM_LEVELS:-7}"
hot_file_level_limit="${HOT_FILE_LEVEL_LIMIT:-1}"
hash_fanout="${HASH_FANOUT:-4}"
hash_compaction_trigger="${HASH_COMPACTION_TRIGGER:-4}"
hash_compaction_file_limit="${HASH_COMPACTION_FILE_LIMIT:-0}"
write_buffer_size="${WRITE_BUFFER_SIZE:-$((128 * 1024 * 1024))}"
target_file_size_base="${TARGET_FILE_SIZE_BASE:-$((32 * 1024 * 1024))}"
max_background_jobs="${MAX_BACKGROUND_JOBS:-8}"
max_subcompactions="${MAX_SUBCOMPACTIONS:-1}"
block_cache_size="${BLOCK_CACHE_SIZE:-0}"
bloom_bits="${BLOOM_BITS:-10}"
disable_trivial_move="${DISABLE_TRIVIAL_MOVE:-true}"
level0_file_num_compaction_trigger="${LEVEL0_FILE_NUM_COMPACTION_TRIGGER:-4}"
universal_size_ratio="${UNIVERSAL_SIZE_RATIO:-1}"
universal_min_merge_width="${UNIVERSAL_MIN_MERGE_WIDTH:-2}"
universal_max_size_amplification_percent="${UNIVERSAL_MAX_SIZE_AMPLIFICATION_PERCENT:-200}"
universal_allow_trivial_move="${UNIVERSAL_ALLOW_TRIVIAL_MOVE:-false}"
universal_incremental="${UNIVERSAL_INCREMENTAL:-false}"

run_id="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
data_root="${DATA_ROOT:-/localdata/benchmark}"
wal_root="${WAL_ROOT:-/nvmedata/benchmark}"
result_dir="${RESULT_ROOT:-${repo_root}/results}/${run_id}"

rocksdb_cloud_path="${data_root}/${run_id}/ycsb-rocksdb-cloud"
rocksdb_cloud_wal="${wal_root}/${run_id}/ycsb-rocksdb-cloud"
rocksdb_tiering_path="${data_root}/${run_id}/ycsb-rocksdb-cloud-tiering"
rocksdb_tiering_wal="${wal_root}/${run_id}/ycsb-rocksdb-cloud-tiering"
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
  "${rocksdb_tiering_path}" "${rocksdb_tiering_wal}" \
  "${lsm_hash_path}" "${lsm_hash_wal}"

{
  echo "benchmark_profile=${benchmark_profile}"
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
  echo "hash_compaction_trigger=${hash_compaction_trigger}"
  echo "hash_compaction_file_limit=${hash_compaction_file_limit}"
  echo "write_buffer_size=${write_buffer_size}"
  echo "target_file_size_base=${target_file_size_base}"
  echo "max_background_jobs=${max_background_jobs}"
  echo "max_subcompactions=${max_subcompactions}"
  echo "block_cache_size=${block_cache_size}"
  echo "bloom_bits=${bloom_bits}"
  echo "disable_trivial_move=${disable_trivial_move}"
  echo "level0_file_num_compaction_trigger=${level0_file_num_compaction_trigger}"
  echo "universal_size_ratio=${universal_size_ratio}"
  echo "universal_min_merge_width=${universal_min_merge_width}"
  echo "universal_max_size_amplification_percent=${universal_max_size_amplification_percent}"
  echo "universal_allow_trivial_move=${universal_allow_trivial_move}"
  echo "universal_incremental=${universal_incremental}"
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

save_hash_monitors() {
  local phase=$1
  local db_path=$2
  local benchmark_log=$3
  local previous_inode=$4
  local previous_size=$5
  local db_log="${db_path}/LOG"
  local current_inode=""

  awk '
    /db statistics before balance/ { snapshot = "before_balance" }
    /db statistics after balance/ { snapshot = "after_balance" }
    /^\*\* LSM-Hash bucket stats / {
      print "snapshot=" (snapshot == "" ? "unknown" : snapshot)
      capture = 1
    }
    capture { print }
    capture && /^$/ { capture = 0 }
  ' "${benchmark_log}" >"${result_dir}/${phase}-hash-buckets.log"
  if [[ -f "${db_log}" ]]; then
    current_inode=$(stat -c '%i' "${db_log}")
    if [[ -n "${previous_inode}" && "${current_inode}" == "${previous_inode}" ]]; then
      tail -c "+$((previous_size + 1))" "${db_log}" \
        | grep '"hash_compaction_type"' \
        >"${result_dir}/${phase}-hash-compactions.log" || true
    else
      grep '"hash_compaction_type"' "${db_log}" \
        >"${result_dir}/${phase}-hash-compactions.log" || true
    fi
  else
    : >"${result_dir}/${phase}-hash-compactions.log"
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
  local compaction_style=$6
  local workload_file=$7
  local load=$8
  local run=$9
  local insert_start=${10}
  local phase_operation_count=${11}
  local log_file="${result_dir}/${case_name}-${phase_name}.log"
  local hash_log_inode=""
  local hash_log_size=0

  echo "Starting ${case_name}: ${phase_name}"
  if (( fanout > 0 )) && [[ -f "${db_path}/LOG" ]]; then
    hash_log_inode=$(stat -c '%i' "${db_path}/LOG")
    hash_log_size=$(stat -c '%s' "${db_path}/LOG")
  fi
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
      -p "compaction_style=${compaction_style}" \
      -p "num_levels=${num_levels}" \
      -p "level0_file_num_compaction_trigger=${level0_file_num_compaction_trigger}" \
      -p "hot_file_level_limit=${hot_file_level_limit}" \
      -p "hash_fanout=${fanout}" \
      -p "hash_compaction_trigger=${hash_compaction_trigger}" \
      -p "hash_compaction_file_limit=${hash_compaction_file_limit}" \
      -p "disable_trivial_move=${disable_trivial_move}" \
      -p "universal_size_ratio=${universal_size_ratio}" \
      -p "universal_min_merge_width=${universal_min_merge_width}" \
      -p "universal_max_size_amplification_percent=${universal_max_size_amplification_percent}" \
      -p "universal_allow_trivial_move=${universal_allow_trivial_move}" \
      -p "universal_incremental=${universal_incremental}" \
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
  if (( fanout > 0 )); then
    save_hash_monitors "${case_name}-${phase_name}" "${db_path}" "${log_file}" \
      "${hash_log_inode}" "${hash_log_size}"
  fi
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
  local compaction_style=$5
  local workload

  run_ycsb_phase "${case_name}" load "${db_path}" "${wal_path}" \
    "${fanout}" "${compaction_style}" \
    "${repo_root}/workloads/workloada.spec" true false 0 \
    "${workload_ops[a]}"

  for workload in "${workloads[@]}"; do
    run_ycsb_phase "${case_name}" "workload-${workload}" \
      "${db_path}" "${wal_path}" "${fanout}" \
      "${compaction_style}" \
      "${repo_root}/workloads/workload${workload}.spec" false true \
      "${record_count}" "${workload_ops[${workload}]}"
  done

  cleanup_case "${case_name}" "${db_path}" "${wal_path}"
}

# This bucket is dedicated to the benchmark. Clear leftovers before the first DB.
empty_bucket "pre-run cleanup"

run_case rocksdb-cloud "${rocksdb_cloud_path}" "${rocksdb_cloud_wal}" 0 0
run_case rocksdb-cloud-tiering "${rocksdb_tiering_path}" \
  "${rocksdb_tiering_wal}" 0 1
run_case lsm-hash "${lsm_hash_path}" "${lsm_hash_wal}" "${hash_fanout}" 0

grep -hE '^(loading records:|all operation records:)' \
  "${result_dir}"/*.log >"${result_dir}/summary.log" || true

stop_monitors
trap - EXIT INT TERM
echo "All YCSB tests completed. Results: ${result_dir}"
