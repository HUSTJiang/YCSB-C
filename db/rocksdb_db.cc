#include "rocksdb_db.h"

#include <aws/core/Aws.h>

#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <utility>

#include "lib/coding.h"
#include "rocksdb/cache.h"
#include "rocksdb/cloud/cloud_file_system.h"
#include "rocksdb/filter_policy.h"
#include "rocksdb/options.h"
#include "rocksdb/statistics.h"
#include "rocksdb/table.h"

namespace ycsbc {
namespace {

constexpr uint64_t kMiB = 1024ULL * 1024ULL;

uint64_t GetUint64(const utils::Properties& props, const std::string& name,
                   uint64_t default_value) {
  return std::stoull(props.GetProperty(name, std::to_string(default_value)));
}

bool GetBool(const utils::Properties& props, const std::string& name,
             bool default_value) {
  return utils::StrToBool(
      props.GetProperty(name, default_value ? "true" : "false"));
}

class AwsApiGuard {
 public:
  AwsApiGuard() { Aws::InitAPI(options_); }
  ~AwsApiGuard() { Aws::ShutdownAPI(options_); }

 private:
  Aws::SDKOptions options_;
};

void EnsureAwsApiInitialized() {
  static AwsApiGuard guard;
  (void)guard;
}

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << message << std::endl;
  std::exit(EXIT_FAILURE);
}

}  // namespace

RocksDB::RocksDB(const char* dbfilename, utils::Properties& props)
    : db_(nullptr),
      cloud_db_(false),
      raw_values_(GetBool(props, "rawvalues", false)),
      no_result_(0) {
  rocksdb::Options options;
  SetOptions(&options, props, dbfilename);

  rocksdb::Status status;
  if (cloud_db_) {
    rocksdb::DBCloud* cloud_db = nullptr;
    status = rocksdb::DBCloud::Open(options, dbfilename,
                                    "" /* persistent_cache_path */,
                                    0 /* persistent_cache_size_gb */,
                                    &cloud_db);
    db_ = cloud_db;
  } else {
    status = rocksdb::DB::Open(options, dbfilename, &db_);
  }
  if (!status.ok()) {
    Fail("Unable to open RocksDB at " + std::string(dbfilename) + ": " +
         status.ToString());
  }
}

void RocksDB::SetOptions(rocksdb::Options* options,
                         const utils::Properties& props,
                         const char* dbfilename) {
  options->create_if_missing = true;
  options->compression = rocksdb::kNoCompression;
  options->num_levels = static_cast<int>(GetUint64(props, "num_levels", 7));
  options->hot_file_level_limit =
      static_cast<int>(GetUint64(props, "hot_file_level_limit", 1));
  options->hash_fanout =
      static_cast<uint32_t>(GetUint64(props, "hash_fanout", 0));
  options->write_buffer_size =
      GetUint64(props, "write_buffer_size", 128ULL * kMiB);
  options->target_file_size_base =
      GetUint64(props, "target_file_size_base", 32ULL * kMiB);
  options->max_background_jobs =
      static_cast<int>(GetUint64(props, "max_background_jobs", 8));
  options->max_subcompactions =
      static_cast<uint32_t>(GetUint64(props, "max_subcompactions", 1));
  options->use_direct_reads =
      GetBool(props, "use_direct_reads", true);
  options->use_direct_io_for_flush_and_compaction =
      GetBool(props, "use_direct_io_for_flush_and_compaction", true);
  options->report_bg_io_stats =
      GetBool(props, "report_bg_io_stats", true);
  options->wal_dir = props.GetProperty("wal_dir", "/nvmedata/benchmark/ycsb");

  statistics_ = rocksdb::CreateDBStatistics();
  options->statistics = statistics_;

  rocksdb::BlockBasedTableOptions table_options;
  const int bloom_bits =
      static_cast<int>(GetUint64(props, "bloom_bits", 10));
  if (bloom_bits > 0) {
    table_options.filter_policy.reset(
        rocksdb::NewBloomFilterPolicy(bloom_bits));
  }
  const uint64_t block_cache_size =
      GetUint64(props, "block_cache_size", 0);
  if (block_cache_size == 0) {
    table_options.no_block_cache = true;
  } else {
    table_options.block_cache = rocksdb::NewLRUCache(block_cache_size);
  }
  options->table_factory.reset(
      rocksdb::NewBlockBasedTableFactory(table_options));

  cloud_db_ = props.GetProperty("dboption", "0") == "1";
  if (!cloud_db_) {
    return;
  }

  const char* access_key_id = std::getenv("AWS_ACCESS_KEY_ID");
  const char* secret_access_key = std::getenv("AWS_SECRET_ACCESS_KEY");
  if (access_key_id == nullptr || secret_access_key == nullptr) {
    Fail("Cloud DB requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY");
  }

  EnsureAwsApiInitialized();
  const std::string bucket =
      props.GetProperty("cloud_bucket", "testbucket1-jx");
  const std::string region =
      props.GetProperty("cloud_region", "ap-northeast-1");
  const std::string object_path =
      props.GetProperty("cloud_object_path", dbfilename);

  rocksdb::CloudFileSystemOptions cloud_fs_options;
  cloud_fs_options.credentials.InitializeSimple(access_key_id,
                                                secret_access_key);
  if (!cloud_fs_options.credentials.HasValid().ok()) {
    Fail("Invalid AWS credentials");
  }
  cloud_fs_options.keep_local_sst_files = false;
  cloud_fs_options.keep_local_log_files = true;
  cloud_fs_options.create_bucket_if_missing = false;

  rocksdb::CloudFileSystem* cloud_fs_raw = nullptr;
  rocksdb::Status status = rocksdb::CloudFileSystemEnv::NewAwsFileSystem(
      rocksdb::FileSystem::Default(), bucket, object_path, region, bucket,
      object_path, region, cloud_fs_options, nullptr, &cloud_fs_raw);
  if (!status.ok()) {
    Fail("Unable to create CloudFS for bucket " + bucket + ": " +
         status.ToString());
  }

  std::shared_ptr<rocksdb::FileSystem> cloud_fs(cloud_fs_raw);
  cloud_env_ = rocksdb::CloudFileSystemEnv::NewCompositeEnv(
      rocksdb::Env::Default(), std::move(cloud_fs));
  options->env = cloud_env_.get();
}

int RocksDB::Read(const std::string&, const std::string& key,
                  const std::vector<std::string>*,
                  std::vector<KVPair>& result) {
  std::string value;
  rocksdb::Status status = db_->Get(rocksdb::ReadOptions(), key, &value);
  if (status.ok()) {
    DeSerializeValues(value, result);
    return DB::kOK;
  }
  if (status.IsNotFound()) {
    no_result_.fetch_add(1, std::memory_order_relaxed);
    return DB::kOK;
  }
  Fail("RocksDB read failed: " + status.ToString());
}

int RocksDB::Scan(const std::string&, const std::string& key, int len,
                  const std::vector<std::string>*,
                  std::vector<std::vector<KVPair>>&) {
  std::unique_ptr<rocksdb::Iterator> iterator(
      db_->NewIterator(rocksdb::ReadOptions()));
  iterator->Seek(key);
  for (int i = 0; i < len && iterator->Valid(); ++i) {
    iterator->Next();
  }
  if (!iterator->status().ok()) {
    Fail("RocksDB scan failed: " + iterator->status().ToString());
  }
  return DB::kOK;
}

int RocksDB::Insert(const std::string&, const std::string& key,
                    std::vector<KVPair>& values) {
  std::string value;
  SerializeValues(values, value);
  rocksdb::Status status = db_->Put(rocksdb::WriteOptions(), key, value);
  if (!status.ok()) {
    Fail("RocksDB write failed: " + status.ToString());
  }
  return DB::kOK;
}

int RocksDB::Update(const std::string& table, const std::string& key,
                    std::vector<KVPair>& values) {
  return Insert(table, key, values);
}

int RocksDB::Delete(const std::string&, const std::string& key) {
  rocksdb::Status status = db_->Delete(rocksdb::WriteOptions(), key);
  if (!status.ok()) {
    Fail("RocksDB delete failed: " + status.ToString());
  }
  return DB::kOK;
}

void RocksDB::PrintStats() {
  std::cout << "read not found:"
            << no_result_.load(std::memory_order_relaxed) << std::endl;
  std::string stats;
  if (db_->GetProperty("rocksdb.stats", &stats)) {
    std::cout << stats << std::endl;
  }
  if (statistics_) {
    std::cout << statistics_->ToString() << std::endl;
  }
}

bool RocksDB::HaveBalancedDistribution() {
  rocksdb::Status status = db_->WaitForCompact(rocksdb::WaitForCompactOptions());
  if (!status.ok()) {
    Fail("WaitForCompact failed: " + status.ToString());
  }
  return true;
}

RocksDB::~RocksDB() { delete db_; }

void RocksDB::SerializeValues(const std::vector<KVPair>& kvs,
                              std::string& value) const {
  value.clear();
  if (raw_values_) {
    for (const auto& kv : kvs) {
      value.append(kv.second);
    }
    return;
  }

  PutFixed64(&value, kvs.size());
  for (const auto& kv : kvs) {
    PutFixed64(&value, kv.first.size());
    value.append(kv.first);
    PutFixed64(&value, kv.second.size());
    value.append(kv.second);
  }
}

void RocksDB::DeSerializeValues(const std::string& value,
                                std::vector<KVPair>& kvs) const {
  if (raw_values_) {
    kvs.emplace_back("field0", value);
    return;
  }
  if (value.size() < sizeof(uint64_t)) {
    Fail("Corrupt serialized YCSB value");
  }

  size_t offset = 0;
  const uint64_t kv_count = DecodeFixed64(value.data());
  offset += sizeof(uint64_t);
  for (uint64_t i = 0; i < kv_count; ++i) {
    if (offset + sizeof(uint64_t) > value.size()) {
      Fail("Corrupt serialized YCSB field name");
    }
    const uint64_t field_name_size = DecodeFixed64(value.data() + offset);
    offset += sizeof(uint64_t);
    if (offset + field_name_size + sizeof(uint64_t) > value.size()) {
      Fail("Corrupt serialized YCSB field name length");
    }
    std::string field_name(value.data() + offset, field_name_size);
    offset += field_name_size;

    const uint64_t field_value_size = DecodeFixed64(value.data() + offset);
    offset += sizeof(uint64_t);
    if (offset + field_value_size > value.size()) {
      Fail("Corrupt serialized YCSB field value length");
    }
    kvs.emplace_back(std::move(field_name),
                     std::string(value.data() + offset, field_value_size));
    offset += field_value_size;
  }
}

}  // namespace ycsbc
