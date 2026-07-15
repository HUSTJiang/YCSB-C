CXX ?= g++

ROCKSDB_ROOT ?= /home/jx/LSM-Hash
ROCKSDB_INCLUDE ?= $(ROCKSDB_ROOT)/include
ROCKSDB_LIB_DIR ?= $(ROCKSDB_ROOT)/build
AWS_INCLUDE ?= /usr/local/include
AWS_LIB_DIR ?= /usr/local/lib

CPPFLAGS += -I. -I$(ROCKSDB_INCLUDE) -I$(AWS_INCLUDE)
CPPFLAGS += -DUSE_AWS -DROCKSDB_USE_RTTI
CXXFLAGS ?= -O3 -DNDEBUG
CXXFLAGS += -std=c++20 -Wall -Wextra -pthread -MMD -MP
LDFLAGS += -L$(ROCKSDB_LIB_DIR) -L$(AWS_LIB_DIR)
LDFLAGS += -Wl,-rpath,$(ROCKSDB_LIB_DIR):$(AWS_LIB_DIR)
LDLIBS += -lrocksdb -laws-cpp-sdk-s3 -laws-cpp-sdk-core -pthread -ldl

SOURCES := ycsbc.cc $(wildcard core/*.cc) $(wildcard db/*.cc)
OBJECTS := $(SOURCES:.cc=.o)
DEPS := $(OBJECTS:.o=.d)
EXEC := ycsbc

all: $(EXEC)

$(EXEC): $(OBJECTS)
	$(CXX) $(LDFLAGS) $^ $(LDLIBS) -o $@

%.o: %.cc
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

clean:
	$(RM) $(OBJECTS) $(DEPS) $(EXEC)

-include $(DEPS)

.PHONY: all clean
