#!/bin/bash
# 当前性能测试 - 使用稳定配置

BASE_DIR="/home/kkk/code/Order-Fairness/Rashnu"
cd "$BASE_DIR"

echo "当前性能测试 - 稳定配置"
echo "================================================"

# 清理
echo "清理进程..."
pkill -9 -f "hotstuff-app" 2>/dev/null || true
pkill -9 -f "hotstuff-client" 2>/dev/null || true
sleep 3
rm -f log* client*.log current_perf.txt

# 使用更保守的配置避免段错误
echo "启动副本（保守配置）..."
for i in {0..4}; do
    "$BASE_DIR/examples/hotstuff-app" \
        --conf "$BASE_DIR/hotstuff-sec$i.conf" \
        --nworker 8 \
        --repnworker 4 \
        --clinworker 4 \
        --repburst 200 \
        --cliburst 2000 \
        --max-rep-msg 4194304 \
        --max-cli-msg 4194304 \
        > "log$i" 2>&1 &
    echo "  副本$i 启动"
done

# 等待预热
echo "等待20s预热..."
sleep 20

# 启动客户端
echo "启动客户端，测试30s..."
timeout 30 \
    "$BASE_DIR/examples/hotstuff-client" \
    --idx 0 \
    --iter -1 \
    --max-async 1600 \
    2>&1 | tee client_raw.log | grep "hotstuff info" > "client.log" &

# 等待测试
sleep 35

# 停止
echo "停止进程..."
pkill -9 -f "hotstuff-app" 2>/dev/null || true
pkill -9 -f "hotstuff-client" 2>/dev/null || true
sleep 2

# 分析
echo ""
echo "性能分析..."
echo "--------------------------------"

if [ -f client.log ] && [ -s client.log ]; then
    LINE_COUNT=$(wc -l < client.log)
    echo "延迟测量数: $LINE_COUNT"
    
    # 计算平均延迟
    TOTAL=0
    COUNT=0
    while read -r line; do
        LATENCY=$(echo "$line" | awk '{print $NF}')
        if [[ $LATENCY =~ ^[0-9.]+$ ]]; then
            TOTAL=$(echo "$TOTAL + $LATENCY" | bc -l 2>/dev/null || echo "$TOTAL")
            COUNT=$((COUNT + 1))
        fi
    done < client.log
    
    if [ $COUNT -gt 0 ]; then
        AVG_SEC=$(echo "scale=6; $TOTAL / $COUNT" | bc -l 2>/dev/null || echo "0")
        AVG_MS=$(echo "scale=3; $AVG_SEC * 1000" | bc -l 2>/dev/null || echo "0")
        AVG_MS_INT=$(echo "$AVG_MS" | cut -d. -f1)
        
        echo "平均延迟: ${AVG_MS_INT}ms"
        
        # 估算TPS (Little's Law: TPS = 并发数 / 平均延迟)
        if [ $AVG_MS_INT -gt 0 ]; then
            EST_TPS=$((1600 * 1000 / $AVG_MS_INT))
            echo "估算TPS: $EST_TPS"
            
            # 考虑区块大小
            BLOCK_SIZE=400
            EST_TX_TPS=$((EST_TPS * BLOCK_SIZE))
            echo "估算交易TPS: $EST_TX_TPS"
        fi
    fi
    
    # 检查错误
    ERROR_COUNT=0
    for i in {0..4}; do
        if [ -f "log$i" ]; then
            ERR=$(grep -c -i "error\|Error\|ERROR\|segmentation\|段错误" "log$i" 2>/dev/null || true)
            ERR=${ERR:-0}
            ERROR_COUNT=$((ERROR_COUNT + ERR))
        fi
    done
    
    if [ $ERROR_COUNT -gt 0 ]; then
        echo "警告: 发现 $ERROR_COUNT 个错误"
    else
        echo "状态: 无错误"
    fi
    
    # 保存结果
    echo "配置: nworker=8, repnworker=4, clinworker=4" > current_perf.txt
    echo "       repburst=200, cliburst=2000" >> current_perf.txt
    echo "       max-async=1600" >> current_perf.txt
    echo "延迟测量数: $LINE_COUNT" >> current_perf.txt
    echo "平均延迟: ${AVG_MS_INT}ms" >> current_perf.txt
    if [ $AVG_MS_INT -gt 0 ]; then
        echo "估算TPS: $EST_TPS" >> current_perf.txt
        echo "估算交易TPS: $EST_TX_TPS" >> current_perf.txt
    fi
    echo "错误数: $ERROR_COUNT" >> current_perf.txt
    
else
    echo "错误: 没有生成客户端日志"
    echo "原始输出:"
    tail -n 20 client_raw.log 2>/dev/null || echo "无输出"
fi

echo ""
echo "副本0最后状态:"
if [ -f log0 ]; then
    tail -n 10 log0 2>/dev/null | grep -E "delivered|decided|stat|avg" || echo "无状态信息"
else
    echo "log0不存在"
fi

echo "================================================"
echo "测试完成"
echo "结果保存到: current_perf.txt"