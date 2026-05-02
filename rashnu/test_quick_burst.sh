#!/bin/bash
# 快速测试burst参数优化

BASE_DIR="/home/kkk/code/Order-Fairness/Rashnu"
cd "$BASE_DIR"

# 测试配置：优化配置 (repburst=300, cliburst=3000)
REP_BURST=300
CLI_BURST=3000
N_WORKER=12
REP_NWORKER=8
CLI_NWORKER=4
MAX_ASYNC=3000
BLOCK_SIZE=400
TEST_DURATION=30  # 缩短测试时间
WARMUP_TIME=15

echo "快速测试: repburst=$REP_BURST, cliburst=$CLI_BURST"
echo "================================================"

# 清理
pkill -9 -f hotstuff-app 2>/dev/null || true
pkill -9 -f hotstuff-client 2>/dev/null || true
rm -f log* client*.log

# 启动副本
echo "启动副本..."
for i in {0..4}; do
    "$BASE_DIR/examples/hotstuff-app" \
        --conf "$BASE_DIR/hotstuff-sec$i.conf" \
        --nworker $N_WORKER \
        --repnworker $REP_NWORKER \
        --repburst $REP_BURST \
        --max-rep-msg 4194304 \
        > "log$i" 2>&1 &
    echo "  副本$i 启动"
done

sleep $WARMUP_TIME

# 启动客户端
echo "启动客户端..."
timeout $TEST_DURATION \
    "$BASE_DIR/examples/hotstuff-client" \
    --idx 0 \
    --iter -1 \
    --max-async $MAX_ASYNC \
    --clinworker $CLI_NWORKER \
    --cliburst $CLI_BURST \
    --max-cli-msg 4194304 \
    2>&1 | grep "hotstuff info" > "client0.log" &

sleep $((TEST_DURATION + 5))

# 停止
pkill -9 -f hotstuff-app 2>/dev/null || true
pkill -9 -f hotstuff-client 2>/dev/null || true

# 分析结果
if [ -f client0.log ] && [ -s client0.log ]; then
    TOTAL_COMMITS=$(wc -l < client0.log)
    TPS=$((TOTAL_COMMITS * BLOCK_SIZE / TEST_DURATION))
    
    echo "结果:"
    echo "  总提交数: $TOTAL_COMMITS"
    echo "  TPS: $TPS"
    
    # 检查是否有错误
    if grep -q "error\|Error\|ERROR\|failed\|Failed" log0; then
        echo "警告: 日志中发现错误"
        grep -i "error\|failed" log0 | head -5
    fi
    
    # 显示最后几条日志
    echo "副本0最后日志:"
    tail -n 5 log0
else
    echo "错误: 没有生成客户端日志"
    echo "副本0日志:"
    tail -n 20 log0
fi