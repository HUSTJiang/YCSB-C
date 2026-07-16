# Yahoo! Cloud System Benchmark
# Workload A: Update heavy workload
#   Application example: Session store recording recent actions
#                        
#   Read/update ratio: 50/50
#   Data shape: one raw 1 KiB value with a 16-byte key
#   Request distribution: zipfian
fieldcount=1
fieldlength=1024
keylength=16
rawvalues=true

recordcount=50000000
operationcount=5000000
workload=com.yahoo.ycsb.workloads.CoreWorkload

readallfields=true

readproportion=0.5
updateproportion=0.5
scanproportion=0
insertproportion=0

requestdistribution=zipfian
