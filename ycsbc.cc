//
//  ycsbc.cc
//  YCSB-C
//
//  Created by Jinglei Ren on 12/19/14.
//  Copyright (c) 2014 Jinglei Ren <jinglei@ren.systems>.
//

#include <atomic>
#include <cinttypes>
#include <cstring>
#include <string>
#include <iostream>
#include <vector>
#include <future>
#include <unistd.h>
#include "core/utils.h"
#include "core/timer.h"
#include "core/client.h"
#include "core/core_workload.h"
#include "db/db_factory.h"
#include "rocksdb/perf_level.h"

using namespace std;

std::atomic<uint64_t> ops_cnt[ycsbc::Operation::READMODIFYWRITE + 1] = {};
std::atomic<uint64_t> ops_time[ycsbc::Operation::READMODIFYWRITE + 1] = {};


void UsageMessage(const char *command);
bool StrStartWith(const char *str, const char *pre);
string ParseCommandLine(int argc, const char *argv[], utils::Properties &props);
void Init(utils::Properties &props);
void PrintInfo(utils::Properties &props);

int DelegateClient(ycsbc::DB *db, ycsbc::CoreWorkload *wl, const int num_ops,
    bool is_loading) {
  rocksdb::SetPerfLevel(rocksdb::kEnableTimeAndCPUTimeExceptForMutex);
  db->Init();
  ycsbc::Client client(*db, *wl);
  int oks = 0;
  int next_report_ = 0;
  for (int i = 0; i < num_ops; ++i) {

    if (i >= next_report_) {
        if      (next_report_ < 1000)   next_report_ += 100;
        else if (next_report_ < 5000)   next_report_ += 500;
        else if (next_report_ < 10000)  next_report_ += 1000;
        else if (next_report_ < 50000)  next_report_ += 5000;
        else if (next_report_ < 100000) next_report_ += 10000;
        else if (next_report_ < 500000) next_report_ += 50000;
        else                            next_report_ += 100000;
        fprintf(stderr, "... finished %d ops%30s\r", i, "");
        fflush(stderr);
    }
    if (is_loading) {
      oks += client.DoInsert();
    } else {
      oks += client.DoTransaction();
    }
  }
  db->Close();
  return oks;
}

int main( const int argc, const char *argv[]) {
  utils::Properties props;
  Init(props);
  string file_name = ParseCommandLine(argc, argv, props);

  ycsbc::DB *db = ycsbc::DBFactory::CreateDB(props);
  if (!db) {
    cout << "Unknown database name " << props["dbname"] << endl;
    exit(0);
  }

  const bool load = utils::StrToBool(props.GetProperty("load","false"));
  const bool run = utils::StrToBool(props.GetProperty("run","false"));
  const int num_threads = stoi(props.GetProperty("threadcount", "1"));
  const bool print_stats = utils::StrToBool(props["dbstatistics"]);
  const bool wait_for_balance = utils::StrToBool(props["dbwaitforbalance"]);

  vector<future<int>> actual_ops;
  int total_ops = 0;
  int sum = 0;
  utils::Timer<double> timer;

  PrintInfo(props);

  if( load ) {
    // Loads data
    ycsbc::CoreWorkload wl;
    wl.Init(props);

    uint64_t load_start = get_now_micros();
    total_ops = stoi(props[ycsbc::CoreWorkload::RECORD_COUNT_PROPERTY]);
    if (total_ops % num_threads != 0) {
      cerr << "recordcount must be divisible by threadcount" << endl;
      exit(1);
    }
    for (int i = 0; i < num_threads; ++i) {
      actual_ops.emplace_back(async(launch::async,
          DelegateClient, db, &wl, total_ops / num_threads, true));
    }
    assert((int)actual_ops.size() == num_threads);

    sum = 0;
    for (auto &n : actual_ops) {
      assert(n.valid());
      sum += n.get();
    }
    uint64_t load_end = get_now_micros();
    uint64_t use_time = load_end - load_start;
    printf("********** load result **********\n");
    printf("loading records:%d  use time:%.3f s  IOPS:%.2f iops\n", sum, 1.0 * use_time*1e-6, 1.0 * sum * 1e6 / use_time );
    printf("*********************************\n");
  } 
  if( run ) {
    // Peforms transactions
    ycsbc::CoreWorkload wl;
    wl.Init(props);

    actual_ops.clear();
    total_ops = stoi(props[ycsbc::CoreWorkload::OPERATION_COUNT_PROPERTY]);
    if (total_ops % num_threads != 0) {
      cerr << "operationcount must be divisible by threadcount" << endl;
      exit(1);
    }
    uint64_t run_start = get_now_micros();
    for (int i = 0; i < num_threads; ++i) {
      actual_ops.emplace_back(async(launch::async,
          DelegateClient, db, &wl, total_ops / num_threads, false));
    }
    assert((int)actual_ops.size() == num_threads);
    sum = 0;
    for (auto &n : actual_ops) {
      assert(n.valid());
      sum += n.get();
    }
    uint64_t run_end = get_now_micros();
    uint64_t use_time = run_end - run_start;

    printf("********** run result **********\n");
    printf("all operation records:%d  use time:%.3f s  IOPS:%.2f iops\n\n", sum, 1.0 * use_time*1e-6, 1.0 * sum * 1e6 / use_time );
    static const char* operation_names[] = {
        "insert", "read", "update", "scan", "rmw"};
    for (int op = ycsbc::INSERT; op <= ycsbc::READMODIFYWRITE; ++op) {
      const uint64_t count = ops_cnt[op].load(std::memory_order_relaxed);
      const uint64_t elapsed = ops_time[op].load(std::memory_order_relaxed);
      if (count == 0 || elapsed == 0) {
        continue;
      }
      printf("%-6s ops:%7" PRIu64
             "  summed latency:%7.3f s  avg latency:%9.2f us\n",
             operation_names[op], count, elapsed * 1e-6,
             static_cast<double>(elapsed) / count);
    }
    printf("********************************\n");
  }
  if ( print_stats ) {
    printf("-------- db statistics before balance --------\n");
    db->PrintStats();
    printf("----------------------------------------------\n");
  }
  if ( wait_for_balance ) {
    uint64_t sleep_time = 0;
    while(!db->HaveBalancedDistribution()){
      sleep(10);
      sleep_time += 10;
    }
    printf("Wait balance:%lu s\n",sleep_time);

    printf("--------- db statistics after balance ---------\n");
    db->PrintStats();
    printf("----------------------------------------------\n");
  }
  delete db;
  return 0;
}

string ParseCommandLine(int argc, const char *argv[], utils::Properties &props) {
  int argindex = 1;
  string filename;
  while (argindex < argc && StrStartWith(argv[argindex], "-")) {
    if (strcmp(argv[argindex], "-threads") == 0) {
      argindex++;
      if (argindex >= argc) {
        UsageMessage(argv[0]);
        exit(0);
      }
      props.SetProperty("threadcount", argv[argindex]);
      argindex++;
    } else if (strcmp(argv[argindex], "-db") == 0) {
      argindex++;
      if (argindex >= argc) {
        UsageMessage(argv[0]);
        exit(0);
      }
      props.SetProperty("dbname", argv[argindex]);
      argindex++;
    } else if (strcmp(argv[argindex], "-host") == 0) {
      argindex++;
      if (argindex >= argc) {
        UsageMessage(argv[0]);
        exit(0);
      }
      props.SetProperty("host", argv[argindex]);
      argindex++;
    } else if (strcmp(argv[argindex], "-port") == 0) {
      argindex++;
      if (argindex >= argc) {
        UsageMessage(argv[0]);
        exit(0);
      }
      props.SetProperty("port", argv[argindex]);
      argindex++;
    } else if (strcmp(argv[argindex], "-slaves") == 0) {
      argindex++;
      if (argindex >= argc) {
        UsageMessage(argv[0]);
        exit(0);
      }
      props.SetProperty("slaves", argv[argindex]);
      argindex++;
    } else if(strcmp(argv[argindex],"-dbpath")==0){
      argindex++;
      if (argindex >= argc) {
        UsageMessage(argv[0]);
        exit(0);
      }
      props.SetProperty("dbpath", argv[argindex]);
      argindex++;
    } else if(strcmp(argv[argindex],"-load")==0){
      argindex++;
      if(argindex >= argc){
        UsageMessage(argv[0]);
        exit(0);
      }
      props.SetProperty("load",argv[argindex]);
      argindex++;
    } else if(strcmp(argv[argindex],"-run")==0){
      argindex++;
      if(argindex >= argc){
        UsageMessage(argv[0]);
        exit(0);
      }
      props.SetProperty("run",argv[argindex]);
      argindex++;
    } else if(strcmp(argv[argindex],"-dboption")==0){
      argindex++;
      if(argindex >= argc){
        UsageMessage(argv[0]);
        exit(0);
      }
      props.SetProperty("dboption",argv[argindex]);
      argindex++;
    } else if(strcmp(argv[argindex],"-dbstatistics")==0){
      argindex++;
      if(argindex >= argc){
        UsageMessage(argv[0]);
        exit(0);
      }
      props.SetProperty("dbstatistics",argv[argindex]);
      argindex++;
    } else if(strcmp(argv[argindex],"-dbwaitforbalance")==0){
      argindex++;
      if(argindex >= argc){
        UsageMessage(argv[0]);
        exit(0);
      }
      props.SetProperty("dbwaitforbalance",argv[argindex]);
      argindex++;
    } else if (strcmp(argv[argindex], "-p") == 0) {
      argindex++;
      if (argindex >= argc) {
        UsageMessage(argv[0]);
        exit(1);
      }
      const std::string property(argv[argindex]);
      const size_t separator = property.find('=');
      if (separator == std::string::npos || separator == 0) {
        cout << "Invalid property override '" << property
             << "'; expected name=value" << endl;
        exit(1);
      }
      props.SetProperty(property.substr(0, separator),
                        property.substr(separator + 1));
      argindex++;
    } else if (strcmp(argv[argindex], "-P") == 0) {
      argindex++;
      if (argindex >= argc) {
        UsageMessage(argv[0]);
        exit(0);
      }
      filename.assign(argv[argindex]);
      ifstream input(argv[argindex]);
      try {
        props.Load(input);
      } catch (const string &message) {
        cout << message << endl;
        exit(0);
      }
      input.close();
      argindex++;
    } else {
      cout << "Unknown option '" << argv[argindex] << "'" << endl;
      exit(0);
    }
  }

  if (argindex == 1 || argindex != argc) {
    UsageMessage(argv[0]);
    exit(0);
  }

  return filename;
}

void UsageMessage(const char *command) {
  cout << "Usage: " << command << " [options]" << endl;
  cout << "Options:" << endl;
  cout << "  -threads n: execute using n threads (default: 1)" << endl;
  cout << "  -db dbname: specify the name of the DB to use (default: basic)" << endl;
  cout << "  -P propertyfile: load properties from the given file. Multiple files can" << endl;
  cout << "                   be specified, and will be processed in the order specified" << endl;
  cout << "  -p name=value: override a workload or database property" << endl;
}

inline bool StrStartWith(const char *str, const char *pre) {
  return strncmp(str, pre, strlen(pre)) == 0;
}

void Init(utils::Properties &props){
  props.SetProperty("dbname","basic");
  props.SetProperty("dbpath","");
  props.SetProperty("load","false");
  props.SetProperty("run","false");
  props.SetProperty("threadcount","1");
  props.SetProperty("dboption","0");
  props.SetProperty("dbstatistics","false");
  props.SetProperty("dbwaitforbalance","false");
}

void PrintInfo(utils::Properties &props) {
  printf("---- dbname:%s  dbpath:%s ----\n", props["dbname"].c_str(), props["dbpath"].c_str());
  printf("%s", props.DebugString().c_str());
  printf("----------------------------------------\n");
  fflush(stdout);
}
