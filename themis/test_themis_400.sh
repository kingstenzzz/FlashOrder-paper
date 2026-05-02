#!/bin/bash
# Themis 统一性能测试脚本
BASE_DIR="/home/kkk/code/Order-Fairness/Themis_tx"
cd "$BASE_DIR"

echo "Cleaning up..."
pkill -9 -f themis-app || true
pkill -9 -f themis-client || true
rm -f log* client*.log client_total.log

echo "Generating config (BlockSize=100)..."
printf '127.0.0.1\n%.0s' {1..4} > _ips_tmp.txt
python3 scripts/gen_conf.py --prefix hotstuff --ips _ips_tmp.txt --keygen ./themis-keygen --tls-keygen ./themis-tls-keygen --nodes nodes.txt --block-size 100 --pace-maker rr --nworker 8 --repnworker 8 --clinworker 4 --repburst 1000 --cliburst 1000

echo "Starting 4 replicas..."
for i in {0..3}; do
    "$BASE_DIR/examples/themis-app" --conf "$BASE_DIR/hotstuff-sec$i.conf" > "log$i" 2>&1 &
done

echo "Waiting for stabilization (15s)..."
sleep 15

echo "Running benchmark (30s, Max-Async=400)..."
timeout 30 "$BASE_DIR/examples/themis-client" --idx 0 --iter -1 --max-async 400 2>&1 | grep --line-buffered "hotstuff info" > client0.log

echo "Stopping processes..."
pkill -9 -f themis-app || true

echo "Analyzing results..."
if [ -s client0.log ]; then
    python3 "$BASE_DIR/scripts/thr_hist.py" < client0.log
else
    echo "Error: No data."
fi
