# YCSB-C

Yahoo! Cloud Serving Benchmark in C++, a C++ version of YCSB (https://github.com/brianfrankcooper/YCSB/wiki)

## Quick Start

To build YCSB-C on Ubuntu, for example:

```
$ sudo apt-get install libtbb-dev
$ make
```

As the driver for Redis is linked by default, change the runtime library path
to include the hiredis library by:
```
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib
```

Run Workload A with a [TBB](https://www.threadingbuildingblocks.org)-based
implementation of the database, for example:
```
./ycsbc -db tbb_rand -threads 4 -P workloads/workloada.spec
```
Also reference run.sh and run\_redis.sh for the command line. See help by
invoking `./ycsbc` without any arguments.

Note that we do not have load and run commands as the original YCSB. Specify
how many records to load by the recordcount property. Reference properties
files in the workloads dir.

## LSM-Hash Cloud Benchmark

This branch compares the current RocksDB-Cloud baseline with LSM-Hash from
`/home/jx/LSM-Hash`:

- RocksDB-Cloud leveled: `hash_fanout=0`, `compaction_style=0`
- RocksDB-Cloud tiering: `hash_fanout=0`, `compaction_style=1` (Universal)
- LSM-Hash: `hash_fanout=4`
- non-bottom buckets become eligible at `hash_compaction_trigger=4`; the
  default `hash_compaction_file_limit=0` drains every available source file
  independently of fanout; bottom self-compaction remains uncapped
- L0-L1 SSTs stay local and L2+ SSTs are stored in S3
- one DB path is used; CloudFS derives its local `hot` and `cold` subdirectories
- block cache is disabled
- trivial move is disabled so both structures rewrite compaction inputs
- 16-byte keys and raw 1 KiB values are used

Build against the local LSM-Hash Release build:

```bash
make -j72
```

When the repositories are under `/home/ubuntu` on EC2:

```bash
make ROCKSDB_ROOT=/home/ubuntu/LSM-Hash -j72
```

The main comparison script is `run.sh`. It runs RocksDB-Cloud leveled,
RocksDB-Cloud Universal/Tiering, and LSM-Hash in sequence. Its defaults match
the corresponding
`real_test.sh` RocksDB settings: 8 client threads, 7 levels, 128 MiB MemTable,
32 MiB target SST, 8 background jobs, one subcompaction, 10 Bloom bits, no
compression, direct I/O, and no block cache. It sequentially loads 50 million
records and runs workloads A, B, C, D, and F by default. Workload A executes
5 million operations; workloads B, C, D, and F execute 1 million operations
each. This results in about 6.4 million read-path accesses per database case.
Workload F performs a read for both its READ and READ_MODIFY_WRITE operations,
so all 1 million F operations access the read path.

Three profile entry points reproduce the tested data shapes and operation
counts while sharing the implementation in `run.sh`:

| Script | Records | Key / value | A operations | B/C/D/F operations |
| --- | ---: | --- | ---: | ---: |
| `run_74b_12b.sh` | 50 million | 74 B / 12 B | 500,000 | 200,000 |
| `run_16b_1024b_1000w.sh` | 10 million | 16 B / 1 KiB | 500,000 | 100,000 |
| `run_16b_1024b_5000w.sh` | 50 million | 16 B / 1 KiB | 5 million | 1 million |

`run.sh` defaults to the 50-million-record 16 B / 1 KiB profile. The same
profile can also be selected with `BENCHMARK_PROFILE`; explicit variables such
as `RECORD_COUNT`, `KEY_LENGTH`, and `WORKLOAD_A_OPS` still take precedence.

```bash
./run.sh
WORKLOAD_A_OPS=8000000 WORKLOAD_C_OPS=2000000 ./run.sh
WORKLOADS="a b c d e f" WORKLOAD_E_OPS=1000000 ./run.sh
```

Results are written under `results/<run-id>/`. Each load/workload phase has a
separate YCSB log, network log, and `iostat` log. Set `RESULT_ROOT`,
`DATA_ROOT`, `WAL_ROOT`, `IO_DEVICE`, or the uppercase option variables in
`run.sh` to override the defaults. `OPERATION_COUNT` overrides every selected
workload, while `WORKLOAD_A_OPS` through `WORKLOAD_F_OPS` provide independent
overrides. `HASH_COMPACTION_TRIGGER` changes the non-bottom source-bucket
high-water mark. `HASH_COMPACTION_FILE_LIMIT` optionally caps a selected batch;
zero means unlimited. Neither option changes `HASH_FANOUT`.

The tiering case uses the standard Universal defaults explicitly: size ratio
1, minimum merge width 2, maximum size amplification 200%, no incremental
compaction, and no Universal trivial move. Override them with
`UNIVERSAL_SIZE_RATIO`, `UNIVERSAL_MIN_MERGE_WIDTH`,
`UNIVERSAL_MAX_SIZE_AMPLIFICATION_PERCENT`,
`UNIVERSAL_ALLOW_TRIVIAL_MOVE`, and `UNIVERSAL_INCREMENTAL`. All three cases
use `LEVEL0_FILE_NUM_COMPACTION_TRIGGER=4` by default. Universal output paths
are selected from the physical output level, so L0-L1 remain under `hot` and
L2+ are written under `cold` for CloudFS upload.

LSM-Hash phases also emit two dedicated monitor files. `*-hash-buckets.log`
contains the per-logical-level non-empty bucket count, SST bytes, busy files,
trigger backlog, P95 files per bucket, and the largest bucket. Each YCSB phase
labels snapshots as `before_balance` and `after_balance`, so compaction backlog
created by the foreground workload can be distinguished from the drained state.
`*-hash-compactions.log` contains structured `compaction_started` and
`compaction_finished` events for Hash compactions, including source/target
logical levels and partition IDs, source and bottom-overlap bytes, output size,
wall/CPU time, subcompaction count, and file I/O timing. These files are
captured separately for Load and every selected YCSB workload.

`run.sh` treats `testbucket1-jx` as a dedicated benchmark bucket. It deletes
all current objects before the run and after each database case, including
`.rockset/dbid/`, and fails if `list-objects-v2` does not report an empty
bucket. Do not use the script with a bucket containing unrelated data. S3
object versions require separate cleanup when bucket versioning is enabled.

Trivial move is disabled by default for this comparison. Set
`DISABLE_TRIVIAL_MOVE=false` to restore normal RocksDB trivial moves for an
A/B experiment.

For manual runs, database and workload properties can be overridden with
`-p name=value`; `workloads/lsm_hash_common.spec` contains the common data
shape used by the comparison.
