#!/bin/bash
pkill -9 -f hotstuff-app 2>/dev/null || true
pkill -9 -f hotstuff-client 2>/dev/null || true

# 清理旧日志
rm -f log*.log client.log client_raw.log

echo "Generating config..."
printf '127.0.0.1\n%.0s' {1..4} > _ips_tmp.txt
# 生成 4 个副本的配置
python3 scripts/gen_conf.py --prefix hotstuff --ips _ips_tmp.txt --keygen ./hotstuff-keygen --tls-keygen ./hotstuff-tls-keygen --nodes nodes.txt --block-size 100 --pace-maker rr --nworker 8 --repnworker 8 --clinworker 4 --repburst 1000 --cliburst 1000

echo "Starting 4 replicas..."
# 显式启动 0, 1, 2, 3，并重定向日志到 .log 后缀防止被脚本末尾误删
for i in {0..3}; do
    ./examples/flashorder-app --conf hotstuff-sec${i}.conf > log${i}.log 2>&1 &
    echo "  Replica $i started."
done

echo "Waiting for leader election and system stabilization (12s)..."
sleep 12

echo "Starting client for 20s..."
# 增加 --iter -1 确保客户端在 20 秒内一直发送交易
timeout 20 ./examples/flashorder-client --idx 0 --iter -1 --max-async 400 > client_raw.log 2>&1

echo "Stopping replicas..."
pkill -9 -f hotstuff-app 2>/dev/null || true

echo "Extracting throughput data..."
grep "hotstuff info" client_raw.log > client.log

echo "Calculating TPS..."
if [ -s client.log ]; then
  python3 scripts/thr_hist.py < client.log || {
    echo "Failed to analyze data. client.log tail:"
    tail -n 5 client.log
  }
else
  echo "client.log is empty, no transactions committed."
  echo "Last 10 lines of Replica 0 log:"
  tail -n 10 log0.log
fi
