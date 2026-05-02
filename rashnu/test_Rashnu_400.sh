#!/bin/bash
# 性能测试脚本 - 增强型
# 确保在正确的路径
BASE_DIR="/home/kkk/code/Order-Fairness/Rashnu"
cd "$BASE_DIR"

# 1. 清理进程和旧日志
echo "Cleaning up..."
pkill -9 -f hotstuff-app || true
pkill -9 -f hotstuff-client || true
rm -f log* client*.log client_total.log

# 2. 启动副本节点 (5个)
echo "Starting 5 replicas..."
for i in {0..4}; do
    "$BASE_DIR/examples/hotstuff-app" --conf "$BASE_DIR/hotstuff-sec$i.conf" > "log$i" 2>&1 &
done

# 等待选主稳定
echo "Waiting 30s for replicas to stabilize..."
sleep 30

# 3. 启动 1 个客户端
echo "Running 1 client for 60 seconds..."
# 显式传递参数覆盖配置文件中的潜在错误，并确保使用了我们想要的设置
# 注意：我们这里不传递全部参数，因为副本已经通过 .conf 加载了
timeout 60 "$BASE_DIR/examples/hotstuff-client" --idx 0 --iter -1 --max-async 2000 2>&1 | grep "hotstuff info" > client0.log &


# 等待客户端完成 (60s + 缓冲)
sleep 65

# 4. 停止所有进程
echo "Stopping processes..."
pkill -9 -f hotstuff-app || true
pkill -9 -f hotstuff-client || true

# 5. 分析日志
echo "Analyzing results..."
if [ -f client0.log ] && [ -s client0.log ]; then
    cat client*.log > client_total.log
    lines=$(wc -l < client_total.log)
    echo "Total commit records: $lines"
    
    if [ "$lines" -gt 0 ]; then
        echo "Replica 0 log tail (last 5 lines):"
        tail -n 5 log0
        echo "Performance metrics:"
        python3 "$BASE_DIR/scripts/thr_hist.py" < client_total.log
    else
        echo "Error: client_total.log is empty. No transactions were committed."
    fi
else
    echo "Error: client0.log was not generated or is empty."
    echo "Check log0 for potential replica errors:"
    tail -n 20 log0
fi
