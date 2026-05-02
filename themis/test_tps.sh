#!/bin/bash
pkill -9 -f themis-app 2>/dev/null || true
pkill -9 -f themis-client 2>/dev/null || true

rm -f log0 log1 log2 log3 client.log

echo "Generating config..."
printf '127.0.0.1\n%.0s' {1..4} > _ips_tmp.txt
python3 scripts/gen_conf.py --prefix hotstuff --ips _ips_tmp.txt --keygen ./themis-keygen --tls-keygen ./themis-tls-keygen --nodes nodes.txt --block-size 100 --pace-maker rr --nworker 8 --repnworker 8 --clinworker 4 --repburst 1000 --cliburst 1000

echo "Starting replicas using run_demo.sh..."
bash scripts/run_demo.sh > /dev/null 2>&1 &
REPLICA_PID=$!

echo "Waiting for leader election (8s)..."
sleep 8

echo "Starting client using run_demo_client.sh for 20s..."
# Ensure grep is line-buffered so we don't lose data on timeout
timeout 20 bash scripts/run_demo_client.sh 2>&1 | grep --line-buffered "hotstuff info" > client.log

echo "Stopping replicas..."
pkill -9 -f themis-app 2>/dev/null || true
pkill -9 -f themis-client 2>/dev/null || true

echo "Calculating TPS..."
if [ -s client.log ]; then
  python3 scripts/thr_hist.py < client.log || echo "Failed to analyze data"
else
  echo "client.log is empty, cannot calculate TPS."
  # print out tail of original logs if empty to see what happened
  echo "Tail of log0 (replica 0):"
  tail -n 10 log0 2>/dev/null || echo "No log0 found"
fi

rm -f log0 log1 log2 log3
