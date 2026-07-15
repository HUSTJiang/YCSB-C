#ifndef YCSB_C_ROCKSDB_DB_H
#define YCSB_C_ROCKSDB_DB_H

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "core/db.h"
#include "core/properties.h"
#include "rocksdb/cloud/db_cloud.h"
#include "rocksdb/env.h"
#include "rocksdb/statistics.h"

namespace ycsbc {

class RocksDB : public DB {
 public:
  RocksDB(const char* dbfilename, utils::Properties& props);
  ~RocksDB() override;

  int Read(const std::string& table, const std::string& key,
           const std::vector<std::string>* fields,
           std::vector<KVPair>& result) override;
  int Scan(const std::string& table, const std::string& key, int len,
           const std::vector<std::string>* fields,
           std::vector<std::vector<KVPair>>& result) override;
  int Insert(const std::string& table, const std::string& key,
             std::vector<KVPair>& values) override;
  int Update(const std::string& table, const std::string& key,
             std::vector<KVPair>& values) override;
  int Delete(const std::string& table, const std::string& key) override;

  void PrintStats() override;
  bool HaveBalancedDistribution() override;

 private:
  rocksdb::DB* db_;
  bool cloud_db_;
  bool raw_values_;
  std::atomic<uint64_t> no_result_;
  std::unique_ptr<rocksdb::Env> cloud_env_;
  std::shared_ptr<rocksdb::Statistics> statistics_;

  void SetOptions(rocksdb::Options* options,
                  const utils::Properties& props,
                  const char* dbfilename);
  void SerializeValues(const std::vector<KVPair>& kvs,
                       std::string& value) const;
  void DeSerializeValues(const std::string& value,
                         std::vector<KVPair>& kvs) const;
};

}  // namespace ycsbc

#endif  // YCSB_C_ROCKSDB_DB_H
