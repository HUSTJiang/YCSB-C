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

- RocksDB-Cloud: `hash_fanout=0`
- LSM-Hash: `hash_fanout=4`
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

The main comparison script is `run.sh`. Its defaults match the corresponding
`real_test.sh` RocksDB settings: 8 client threads, 7 levels, 128 MiB MemTable,
32 MiB target SST, 8 background jobs, one subcompaction, 10 Bloom bits, no
compression, direct I/O, and no block cache. It sequentially loads 50 million
records and runs workloads A, B, C, D, and F by default. Workload A executes
5 million operations; workloads B, C, D, and F execute 1 million operations
each. This results in about 6.4 million read-path accesses per database case.
Workload F performs a read for both its READ and READ_MODIFY_WRITE operations,
so all 1 million F operations access the read path.

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
overrides.

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
