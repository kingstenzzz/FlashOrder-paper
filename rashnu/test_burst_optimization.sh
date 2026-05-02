#!/bin/bash
# 简化版burst参数优化测试脚本

BASE_DIR="/home/kkk/code/Order-Fairness/Rashnu"
cd "$BASE_DIR"

# 测试配置 - 主要测试不同burst参数
TEST_CONFIGS=(
    # 配置1: 保守配置 (baseline)
    "repburst=100 cliburst=1000 nworker=16 repnworker=16 clinworker=8 max_async=2000"
    
    # 配置2: 优化配置1 (中等激进)
    "repburst=300 cliburst=3000 nworker=12 repnworker=8 clinworker=4 max_async=3000"
    
    # 配置3: 优化配置2 (激进)
    "repburst=500 cliburst=5000 nworker=10 repnworker=6 clinworker=3 max_async=4000"
    
    # 配置4: 优化配置3 (非常激进)
    "repburst=800 cliburst=8000 nworker=8 repnworker=4 clinworker=2 max_async=5000"
)

BLOCK_SIZE=400
TEST_DURATION=60
WARMUP_TIME=30
RESULTS_FILE="burst_optimization_results.csv"

echo "Burst参数优化测试" > $RESULTS_FILE
echo "配置,总提交数,TPS,平均延迟(ms),最小延迟(ms),最大延迟(ms)" >> $RESULTS_FILE

for config_idx in "${!TEST_CONFIGS[@]}"; do
    CONFIG_STR="${TEST_CONFIGS[$config_idx]}"
    
    # 解析配置参数
    REP_BURST=$(echo "$CONFIG_STR" | grep -o 'repburst=[0-9]*' | cut -d= -f2)
    CLI_BURST=$(echo "$CONFIG_STR" | grep -o 'cliburst=[0-9]*' | cut -d= -f2)
    N_WORKER=$(echo "$CONFIG_STR" | grep -o 'nworker=[0-9]*' | cut -d= -f2)
    REP_NWORKER=$(echo "$CONFIG_STR" | grep -o 'repnworker=[0-9]*' | cut -d= -f2)
    CLI_NWORKER=$(echo "$CONFIG_STR" | grep -o 'clinworker=[0-9]*' | cut -d= -f2)
    MAX_ASYNC=$(echo "$CONFIG_STR" | grep -o 'max_async=[0-9]*' | cut -d= -f2)
    
    echo "================================================"
    echo "测试配置 $((config_idx + 1)): $CONFIG_STR"
    echo "================================================"
    
    # 清理进程和日志
    echo "清理进程..."
    pkill -9 -f hotstuff-app 2>/dev/null || true
    pkill -9 -f hotstuff-client 2>/dev/null || true
    rm -f log* client*.log client_total.log
    
    # 启动副本节点
    echo "启动5个副本节点..."
    for i in {0..4}; do
        "$BASE_DIR/examples/hotstuff-app" \
            --conf "$BASE_DIR/hotstuff-sec$i.conf" \
            --nworker $N_WORKER \
            --repnworker $REP_NWORKER \
            --repburst $REP_BURST \
            --max-rep-msg 4194304 \
            > "log$i" 2>&1 &
    done
    
    # 等待预热
    echo "等待${WARMUP_TIME}s预热..."
    sleep $WARMUP_TIME
    
    # 启动客户端（单个客户端简化测试）
    echo "启动客户端，测试${TEST_DURATION}s..."
    timeout $TEST_DURATION \
        "$BASE_DIR/examples/hotstuff-client" \
        --idx 0 \
        --iter -1 \
        --max-async $MAX_ASYNC \
        --clinworker $CLI_NWORKER \
        --cliburst $CLI_BURST \
        --max-cli-msg 4194304 \
        2>&1 | grep "hotstuff info" > "client0.log" &
    
    # 等待测试完成
    sleep $((TEST_DURATION + 5))
    
    # 停止进程
    pkill -9 -f hotstuff-app 2>/dev/null || true
    pkill -9 -f hotstuff-client 2>/dev/null || true
    
    # 分析结果
    if [ -f client0.log ] && [ -s client0.log ]; then
        TOTAL_COMMITS=$(wc -l < client0.log)
        TPS=$((TOTAL_COMMITS * BLOCK_SIZE / TEST_DURATION))
        
        # 提取延迟信息（如果thr_hist.py可用）
        if [ -f "$BASE_DIR/scripts/thr_hist.py" ]; then
            LATENCY_INFO=$(python3 "$BASE_DIR/scripts/thr_hist.py" < client0.log 2>/dev/null | grep -E "avg|min|max")
            AVG_LATENCY=$(echo "$LATENCY_INFO" | grep "avg" | grep -o '[0-9.]*' | head -1)
            MIN_LATENCY=$(echo "$LATENCY_INFO" | grep "min" | grep -o '[0-9.]*' | head -1)
            MAX_LATENCY=$(echo "$LATENCY_INFO" | grep "max" | grep -o '[0-9.]*' | head -1)
        else
            AVG_LATENCY="N/A"
            MIN_LATENCY="N/A"
            MAX_LATENCY="N/A"
        fi
        
        echo "结果:"
        echo "  总提交数: $TOTAL_COMMITS"
        echo "  TPS: $TPS"
        echo "  平均延迟: ${AVG_LATENCY}ms"
        
        # 保存到结果文件
        echo "配置$((config_idx + 1)),$TOTAL_COMMITS,$TPS,${AVG_LATENCY},${MIN_LATENCY},${MAX_LATENCY}" >> $RESULTS_FILE
        
        # 保存详细日志
        mv client0.log "client_config${config_idx}.log"
        for i in {0..4}; do
            mv "log$i" "log_config${config_idx}_$i"
        done
    else
        echo "错误: 没有生成客户端日志"
        echo "配置$((config_idx + 1)),0,0,N/A,N/A,N/A" >> $RESULTS_FILE
    fi
    
    echo ""
    sleep 5  # 等待系统冷却
done

echo "================================================"
echo "所有测试完成!"
echo "结果保存在: $RESULTS_FILE"
echo "================================================"
cat $RESULTS_FILE