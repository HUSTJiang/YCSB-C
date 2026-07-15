# Yahoo! Cloud System Benchmark
# Workload B: Read mostly workload
#   Application example: photo tagging; add a tag is an update, but most operations are to read tags
#                        
#   Read/update ratio: 95/5
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

readproportion=0.95
updateproportion=0.05
scanproportion=0
insertproportion=0

requestdistribution=zipfian
