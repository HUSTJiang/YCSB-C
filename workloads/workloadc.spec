# Yahoo! Cloud System Benchmark
# Workload C: Read only
#   Application example: user profile cache, where profiles are constructed elsewhere (e.g., Hadoop)
#                        
#   Read/update ratio: 100/0
#   Data shape: one raw 12-byte value with a 74-byte key
#   Request distribution: zipfian
fieldcount=1
fieldlength=12
keylength=74
rawvalues=true

recordcount=50000000
operationcount=200000
workload=com.yahoo.ycsb.workloads.CoreWorkload

readallfields=true

readproportion=1
updateproportion=0
scanproportion=0
insertproportion=0

requestdistribution=zipfian

