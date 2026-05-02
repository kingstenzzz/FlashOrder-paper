#!/bin/bash
# 正确的burst参数测试脚本

BASE_DIR="/home/kkk/code/Order-Fairness/Rashnu"
cd "$BASE_DIR"

# 测试配置 - 只对副本设置burst参数
REP_BURST=300      # 副本间网络突发大小
CLI_BURST=3000     # 副本处理客户端请求的突发大小
N_WORKER=12        # 验证线程数
REP_NWORKER=8      # 副本网络线程数
CLI_NWORKER=8      # 客户端网络线程数（副本端）
MAX_ASYNC=3000     # 客户端最大并发
BLOCK_SIZE=400
TEST_DURATION=30
WARMUP_TIME=15

echo "测试配置:"
echo "  repburst=$REP_BURST (副本间网络)"
echo "  cliburst=$CLI_BURST (副本处理客户端)"
echo "  nworker=$N_WORKER"
echo "  repnworker=$REP_NWORKER"
echo "  clinworker=$CLI_NWORKER"
echo "  max-async=$MAX_ASYNC"
echo "================================================"

# 清理
echo "清理..."
pkill -9 -f "hotstuff-app" 2>/dev/null || true
pkill -9 -f "hotstuff-client" 2>/dev/null || true
sleep 2
rm -f log* client*.log burst_test_result.txt

# 启动副本
echo "启动5个副本..."
for i in {0..4}; do
    echo "  副本$i: repburst=$REP_BURST, cliburst=$CLI_BURST"
    "$BASE_DIR/examples/hotstuff-app" \
        --conf "$BASE_DIR/hotstuff-sec$i.conf" \
        --nworker $N_WORKER \
        --repnworker $REP_NWORKER \
        --clinworker $CLI_NWORKER \
        --repburst $REP_BURST \
        --cliburst $CLI_BURST \
        --max-rep-msg 4194304 \
        --max-cli-msg 4194304 \
        > "log$i" 2>&1 &
done

# 等待预热
echo "等待${WARMUP_TIME}s预热..."
sleep $WARMUP_TIME

# 启动客户端
echo "启动客户端，测试${TEST_DURATION}s..."
timeout $TEST_DURATION \
    "$BASE_DIR/examples/hotstuff-client" \
    --idx 0 \
    --iter -1 \
    --max-async $MAX_ASYNC \
    2>&1 | tee client_raw.log | grep "hotstuff info" > "client0.log" &

# 等待测试
sleep $((TEST_DURATION + 5))

# 停止进程
echo "停止进程..."
pkill -9 -f "hotstuff-app" 2>/dev/null || true
pkill -9 -f "hotstuff-client" 2>/dev/null || true
sleep 2

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
        
        # 保存结果
        echo "配置: repburst=$REP_BURST, cliburst=$CLI_BURST" > burst_test_result.txt
        echo "总提交数: $TOTAL_COMMITS" >> burst_test_result.txt
        echo "TPS: $TPS" >> burst_test_result.txt
        
        # 使用thr_hist.py分析延迟
        if [ -f "$BASE_DIR/scripts/thr_hist.py" ]; then
            echo "延迟分析:" >> burst_test_result.txt
            python3 "$BASE_DIR/scripts/thr_hist.py" < client0.log 2>/dev/null >> burst_test_result.txt
            echo "延迟分析:"
            python3 "$BASE_DIR/scripts/thr_hist.py" < client0.log 2>/dev/null | head -10
        fi
        
        # 检查副本日志中的错误
        ERROR_FOUND=0
        for i in {0..4}; do
            if grep -q -i "error\|Error\|ERROR\|failed\|Failed\|exception" "log$i" 2>/dev/null; then
                ERROR_FOUND=1
                echo "警告: log$i 中发现错误" >> burst_test_result.txt
                grep -i "error\|failed\|exception" "log$i" | head -3 >> burst_test_result.txt
            fi
        done
        
        if [ $ERROR_FOUND -eq 0 ]; then
            echo "状态: 无错误" >> burst_test_result.txt
        fi
        
        echo "结果已保存到: burst_test_result.txt"
    else
        echo "错误: 客户端日志为空"
        echo "原始输出最后20行:"
        tail -n 20 client_raw.log 2>/dev/null || echo "无原始日志"
    fi
else
    echo "错误: 没有生成客户端日志"
    echo "检查副本日志..."
    for i in {0..4}; do
        echo "log$i 最后10行:"
        tail -n 10 "log$i" 2>/dev/null || echo "无日志"
        echo "---"
    done
fi

echo ""
echo "副本0统计信息:"
tail -n 20 log0 2>/dev/null | grep -A5 -B5 "delivery time\|avg\|stat" || echo "无统计信息"

echo "================================================"
echo "测试完成"