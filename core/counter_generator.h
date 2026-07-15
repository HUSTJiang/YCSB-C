//
//  counter_generator.h
//  YCSB-C
//
//  Created by Jinglei Ren on 12/9/14.
//  Copyright (c) 2014 Jinglei Ren <jinglei@ren.systems>.
//

#ifndef YCSB_C_COUNTER_GENERATOR_H_
#define YCSB_C_COUNTER_GENERATOR_H_

#include "generator.h"

#include <cstdint>
#include <atomic>

namespace ycsbc {

class CounterGenerator : public Generator<uint64_t> {
 public:
  CounterGenerator(uint64_t start) : counter_(start) { }
  uint64_t Next() { return counter_.fetch_add(1); }
  uint64_t Last() { return counter_.load() - 1; }
  void Set(uint64_t start) { counter_.store(start); }
  void SetAtLeast(uint64_t value) {
    uint64_t current = counter_.load();
    while (current < value &&
           !counter_.compare_exchange_weak(current, value)) {
    }
  }
 private:
  std::atomic<uint64_t> counter_;
};

} // ycsbc

#endif // YCSB_C_COUNTER_GENERATOR_H_
