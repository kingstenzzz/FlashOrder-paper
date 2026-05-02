#!/bin/bash
# Burst参数对比测试

BASE_DIR="/home/kkk/code/Order-Fairness/Rashnu"
cd "$BASE_DIR"

# 测试配置列表
declare -A TEST_CONFIGS
TEST_CONFIGS["baseline"]="repburst=100 cliburst=1000 nworker=16 repnworker=16 clinworker=8"
TEST_CONFIGS["optimized1"]="repburst=300 cliburst=3000 nworker=12 repnworker=8 clinworker=8"
TEST_CONFIGS["optimized2"]="repburst=500 cliburst=5000 nworker=10 repnworker=6 clinworker=6"
TEST_CONFIGS["optimized3"]="repburst=800 cliburst=8000 nworker=8 repnworker=4 clinworker=4"

# 固定参数
MAX_ASYNC=3000
BLOCK_SIZE=400
TEST_DURATION=30
WARMUP_TIME=15
RESULTS_FILE="burst_comparison_results.csv"

echo "Burst参数对比测试" > $RESULTS_FILE
echo "配置名称,repburst,cliburst,nworker,repnworker,clinworker,总延迟数,平均延迟(ms)" >> $RESULTS_FILE

for config_name in "${!TEST_CONFIGS[@]}"; do
    CONFIG_STR="${TEST_CONFIGS[$config_name]}"
    
    # 解析配置
    REP_BURST=$(echo "$CONFIG_STR" | grep -o 'repburst=[0-9]*' | cut -d= -f2)
    CLI_BURST=$(echo "$CONFIG_STR" | grep -o 'cliburst=[0-9]*' | cut -d= -f2)
    N_WORKER=$(echo "$CONFIG_STR" | grep -o 'nworker=[0-9]*' | cut -d= -f2)
    REP_NWORKER=$(echo "$CONFIG_STR" | grep -o 'repnworker=[0-9]*' | cut -d= -f2)
    CLI_NWORKER=$(echo "$CONFIG_STR" | grep -o 'clinworker=[0-9]*' | cut -d= -f2)
    
    echo "================================================"
    echo "测试配置: $config_name"
    echo "  $CONFIG_STR"
    echo "================================================"
    
    # 清理
    echo "清理..."
    pkill -9 -f "hotstuff-app" 2>/dev/null || true
    pkill -9 -f "hotstuff-client" 2>/dev/null || true
    sleep 3
    rm -f log* client*.log
    
    # 启动副本
    echo "启动副本..."
    for i in {0..4}; do
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
    echo "启动客户端..."
    timeout $TEST_DURATION \
        "$BASE_DIR/examples/hotstuff-client" \
        --idx 0 \
        --iter -1 \
        --max-async $MAX_ASYNC \
        2>&1 | grep "hotstuff info" > "client_${config_name}.log" &
    
    # 等待测试
    sleep $((TEST_DURATION + 5))
    
    # 停止
    pkill -9 -f "hotstuff-app" 2>/dev/null || true
    pkill -9 -f "hotstuff-client" 2>/dev/null || true
    sleep 2
    
    # 分析结果
    if [ -f "client_${config_name}.log" ] && [ -s "client_${config_name}.log" ]; then
        TOTAL_LATENCIES=$(wc -l < "client_${config_name}.log")
        
        # 计算平均延迟
        if [ $TOTAL_LATENCIES -gt 0 ]; then
            # 提取所有延迟值并计算平均值
            SUM=0
            COUNT=0
            while read -r line; do
                # 提取延迟值（最后一部分）
                LATENCY=$(echo "$line" | awk '{print $NF}')
                if [[ $LATENCY =~ ^[0-9.]+$ ]]; then
                    SUM=$(echo "$SUM + $LATENCY" | bc -l 2>/dev/null || echo "$SUM")
                    COUNT=$((COUNT + 1))
                fi
            done < "client_${config_name}.log"
            
            if [ $COUNT -gt 0 ]; then
                AVG_LATENCY=$(echo "scale=3; $SUM / $COUNT * 1000" | bc -l 2>/dev/null || echo "N/A")
                AVG_LATENCY_MS=$(echo "$AVG_LATENCY" | cut -d. -f1)
            else
                AVG_LATENCY_MS="N/A"
            fi
            
            echo "结果:"
            echo "  总延迟测量数: $TOTAL_LATENCIES"
            echo "  平均延迟: ${AVG_LATENCY_MS}ms"
            
            # 保存结果
            echo "$config_name,$REP_BURST,$CLI_BURST,$N_WORKER,$REP_NWORKER,$CLI_NWORKER,$TOTAL_LATENCIES,${AVG_LATENCY_MS}" >> $RESULTS_FILE
            
            # 保存日志
            mv "client_${config_name}.log" "client_${config_name}_detailed.log"
            for i in {0..4}; do
                mv "log$i" "log_${config_name}_$i"
            done
        else
            echo "错误: 延迟日志为空"
            echo "$config_name,$REP_BURST,$CLI_BURST,$N_WORKER,$REP_NWORKER,$CLI_NWORKER,0,N/A" >> $RESULTS_FILE
        fi
    else
        echo "错误: 没有生成客户端日志"
        echo "$config_name,$REP_BURST,$CLI_BURST,$N_WORKER,$REP_NWORKER,$CLI_NWORKER,0,N/A" >> $RESULTS_FILE
    fi
    
    echo ""
    echo "冷却5秒..."
    sleep 5
done

echo "================================================"
echo "所有测试完成!"
echo "结果:"
echo "--------------------------------"
cat $RESULTS_FILE
echo "================================================"

# 生成简单分析报告
echo "性能分析报告:" > burst_analysis.txt
echo "===============" >> burst_analysis.txt
echo "测试时间: $(date)" >> burst_analysis.txt
echo "测试时长: ${TEST_DURATION}s 每个配置" >> burst_analysis.txt
echo "" >> burst_analysis.txt

tail -n +3 $RESULTS_FILE | while IFS=, read -r name repburst cliburst nworker repnworker clinworker total_lat avg_lat; do
    if [ "$total_lat" -gt 0 ] && [ "$avg_lat" != "N/A" ]; then
        # 估算TPS（基于延迟和并发）
        if [ "$avg_lat" -gt 0 ]; then
            EST_TPS=$((MAX_ASYNC * 1000 / avg_lat))
            echo "配置: $name" >> burst_analysis.txt
            echo "  repburst=$repburst, cliburst=$cliburst" >> burst_analysis.txt
            echo "  线程: nworker=$nworker, repnworker=$repnworker, clinworker=$clinworker" >> burst_analysis.txt
            echo "  延迟测量数: $total_lat" >> burst_analysis.txt
            echo "  平均延迟: ${avg_lat}ms" >> burst_analysis.txt
            echo "  估算TPS: $EST_TPS" >> burst_analysis.txt
            echo "" >> burst_analysis.txt
        fi
    fi
done

echo "详细分析已保存到: burst_analysis.txt"
cat burst_analysis.txt