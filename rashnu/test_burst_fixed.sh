#!/bin/bash
# 修复版burst参数测试

BASE_DIR="/home/kkk/code/Order-Fairness/Rashnu"
cd "$BASE_DIR"

# 测试配置
REP_BURST=300
CLI_BURST=3000
N_WORKER=12
REP_NWORKER=8
CLI_NWORKER=4
MAX_ASYNC=3000
BLOCK_SIZE=400
TEST_DURATION=30
WARMUP_TIME=15

echo "测试: repburst=$REP_BURST, cliburst=$CLI_BURST"
echo "================================================"

# 清理
echo "清理旧进程..."
pkill -9 -f "hotstuff-app" 2>/dev/null || true
pkill -9 -f "hotstuff-client" 2>/dev/null || true
sleep 2
rm -f log* client*.log

# 启动副本并记录PID
echo "启动5个副本..."
REPLICA_PIDS=()
for i in {0..4}; do
    "$BASE_DIR/examples/hotstuff-app" \
        --conf "$BASE_DIR/hotstuff-sec$i.conf" \
        --nworker $N_WORKER \
        --repnworker $REP_NWORKER \
        --repburst $REP_BURST \
        --max-rep-msg 4194304 \
        > "log$i" 2>&1 &
    PID=$!
    REPLICA_PIDS+=($PID)
    echo "  副本$i PID: $PID"
done

# 等待预热
echo "等待${WARMUP_TIME}s预热..."
sleep $WARMUP_TIME

# 检查副本是否还在运行
for pid in "${REPLICA_PIDS[@]}"; do
    if ! kill -0 $pid 2>/dev/null; then
        echo "错误: 副本进程 $pid 已退出"
        echo "检查日志..."
        tail -n 20 log0
        exit 1
    fi
done

# 启动客户端
echo "启动客户端，测试${TEST_DURATION}s..."
timeout $TEST_DURATION \
    "$BASE_DIR/examples/hotstuff-client" \
    --idx 0 \
    --iter -1 \
    --max-async $MAX_ASYNC \
    --clinworker $CLI_NWORKER \
    --cliburst $CLI_BURST \
    --max-cli-msg 4194304 \
    2>&1 | tee client_raw.log | grep "hotstuff info" > "client0.log" &
CLIENT_PID=$!

# 等待客户端完成
echo "等待客户端测试..."
wait $CLIENT_PID 2>/dev/null
CLIENT_EXIT=$?

# 给副本一点时间处理剩余请求
sleep 3

# 优雅停止副本
echo "停止副本..."
for pid in "${REPLICA_PIDS[@]}"; do
    kill $pid 2>/dev/null
    sleep 0.5
    kill -9 $pid 2>/dev/null 2>/dev/null
done

# 确保清理
pkill -9 -f "hotstuff-app" 2>/dev/null || true
pkill -9 -f "hotstuff-client" 2>/dev/null || true

# 分析结果
echo ""
echo "分析结果..."
echo "--------------------------------"

if [ -f client0.log ] && [ -s client0.log ]; then
    TOTAL_COMMITS=$(wc -l < client0.log)
    if [ $TOTAL_COMMITS -gt 0 ]; then
        TPS=$((TOTAL_COMMITS * BLOCK_SIZE / TEST_DURATION))
        
        echo "总提交数: $TOTAL_COMMITS"
        echo "TPS: $TPS"
        
        # 使用thr_hist.py分析延迟
        if [ -f "$BASE_DIR/scripts/thr_hist.py" ]; then
            echo "延迟分析:"
            python3 "$BASE_DIR/scripts/thr_hist.py" < client0.log 2>/dev/null | head -20
        fi
        
        # 检查错误
        ERROR_COUNT=$(grep -c -i "error\|failed\|exception" log0 2>/dev/null || true)
        ERROR_COUNT=${ERROR_COUNT:-0}
        if [ $ERROR_COUNT -gt 0 ]; then
            echo "警告: 发现 $ERROR_COUNT 个错误"
            grep -i "error\|failed\|exception" log0 | head -5
        fi
    else
        echo "错误: 客户端日志为空"
    fi
else
    echo "错误: 没有生成客户端日志"
    echo "原始客户端输出:"
    tail -n 20 client_raw.log 2>/dev/null || echo "无原始日志"
fi

echo ""
echo "副本0最后日志:"
tail -n 10 log0 2>/dev/null || echo "无日志"

echo "================================================"
echo "测试完成"