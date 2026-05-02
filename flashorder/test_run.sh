#!/bin/bash
# FlashOrder 统一性能测试脚本
pkill -9 -f flashorder-app 2>/dev/null || true
pkill -9 -f flashorder-client 2>/dev/null || true

rm -f log*.log client.log client_raw.log

echo "Generating config (BlockSize=100)..."
printf '127.0.0.1\n%.0s' {1..4} > _ips_tmp.txt
python3 scripts/gen_conf.py --prefix hotstuff --ips _ips_tmp.txt --keygen ./examples/flashorder-keygen --tls-keygen ./examples/flashorder-tls-keygen --nodes nodes.txt --block-size 100 --pace-maker rr --nworker 8 --repnworker 8 --clinworker 4 --repburst 1000 --cliburst 1000

echo "Starting 4 replicas..."
for i in {0..3}; do
    ./examples/flashorder-app --conf hotstuff-sec${i}.conf > log${i}.log 2>&1 &
    echo "  Replica $i started."
done

echo "Waiting for stabilization (15s)..."
sleep 15

echo "Running benchmark (30s, Max-Async=400)..."
timeout 30 ./examples/flashorder-client --idx 0 --iter -1 --max-async 400 > client_raw.log 2>&1

echo "Stopping replicas..."
pkill -9 -f flashorder-app 2>/dev/null || true

echo "Analyzing TPS..."
grep "hotstuff info" client_raw.log > client.log
if [ -s client.log ]; then
  python3 scripts/thr_hist.py < client.log
else
  echo "Error: No data."
fi
