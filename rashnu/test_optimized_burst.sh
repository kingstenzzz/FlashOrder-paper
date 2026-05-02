#!/bin/bash
# 优化版性能测试脚本 - 包含burst参数优化和CPU绑定
# 目标：充分利用32核CPU性能

BASE_DIR="/home/kkk/code/Order-Fairness/Rashnu"
cd "$BASE_DIR"

# 配置参数 - 根据32核CPU优化
BLOCK_SIZE=400
N_WORKER=12           # 验证线程数（减少上下文切换）
REP_NWORKER=8         # 副本网络线程数
CLI_NWORKER=4         # 客户端网络线程数
REP_BURST=300         # 副本网络突发大小（优化值）
CLI_BURST=3000        # 客户端网络突发大小（优化值）
MAX_ASYNC=3000        # 客户端最大并发
TEST_DURATION=60      # 测试持续时间（秒）
WARMUP_TIME=30        # 预热时间（秒）

# CPU核心分配策略（i9-13900: 32逻辑核心）
# P核心 (0-15): 高性能核心，适合计算密集型任务
# E核心 (16-31): 能效核心，适合I/O和网络任务
REPLICA_CPUS=(
    "0-3,16-17"    # Replica 0: P核心0-1 + E核心16-17
    "4-7,18-19"    # Replica 1: P核心2-3 + E核心18-19  
    "8-11,20-21"   # Replica 2: P核心4-5 + E核心20-21
    "12-15,22-23"  # Replica 3: P核心6-7 + E核心22-23
    "24-27"        # Replica 4: E核心集群1
)

CLIENT_CPUS=(
    "28-29"        # Client 0: E核心
    "30-31"        # Client 1: E核心
    "24-25"        # Client 2: E核心（与Replica 4共享）
    "26-27"        # Client 3: E核心（与Replica 4共享）
)

echo "================================================"
echo "优化版性能测试 - 32核CPU优化配置"
echo "================================================"
echo "配置参数:"
echo "  block-size: $BLOCK_SIZE"
echo "  nworker: $N_WORKER"
echo "  repnworker: $REP_NWORKER"
echo "  clinworker: $CLI_NWORKER"
echo "  repburst: $REP_BURST"
echo "  cliburst: $CLI_BURST"
echo "  max-async: $MAX_ASYNC"
echo "  CPU绑定: 启用"
echo "  测试时长: ${TEST_DURATION}s"
echo "================================================"

# 1. 清理进程和旧日志
echo "清理进程和日志..."
pkill -9 -f hotstuff-app 2>/dev/null || true
pkill -9 -f hotstuff-client 2>/dev/null || true
rm -f log* client*.log client_total.log perf_stats.log

# 2. 启动监控脚本（后台运行）
echo "启动性能监控..."
(
    echo "时间,CPU使用%,内存使用%,上下文切换/s" > perf_stats.log
    for i in $(seq 1 $((TEST_DURATION + WARMUP_TIME + 10))); do
        # 获取系统性能指标
        CPU=$(mpstat 1 1 | tail -1 | awk '{print 100 - $NF}')
        MEM=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
        CTX=$(vmstat 1 2 | tail -1 | awk '{print $12}')
        echo "$(date +%s),$CPU,$MEM,$CTX" >> perf_stats.log
        sleep 1
    done
) &
MONITOR_PID=$!

# 3. 启动副本节点 (5个) - 使用CPU绑定
echo "启动5个副本节点（CPU绑定）..."
for i in {0..4}; do
    CPU_SET="${REPLICA_CPUS[$i]}"
    echo "  Replica $i -> CPUs: $CPU_SET"
    
    # 通过命令行参数传递所有配置，避免配置文件警告
    taskset -c $CPU_SET "$BASE_DIR/examples/hotstuff-app" \
        --conf "$BASE_DIR/hotstuff-sec$i.conf" \
        --nworker $N_WORKER \
        --repnworker $REP_NWORKER \
        --repburst $REP_BURST \
        --max-rep-msg 4194304 \
        > "log$i" 2>&1 &
    REPLICA_PIDS[$i]=$!
    echo "    PID: ${REPLICA_PIDS[$i]}"
done

# 4. 等待选主稳定
echo "等待${WARMUP_TIME}s让副本稳定..."
sleep $WARMUP_TIME

# 5. 启动多个客户端 - 使用CPU绑定
echo "启动4个客户端（CPU绑定）..."
CLIENT_COUNT=4
CLIENT_ASYNC=$((MAX_ASYNC / CLIENT_COUNT))  # 每个客户端的并发数

for i in {0..3}; do
    CPU_SET="${CLIENT_CPUS[$i]}"
    CLIENT_ID=$i
    echo "  Client $CLIENT_ID -> CPUs: $CPU_SET, max-async: $CLIENT_ASYNC"
    
    taskset -c $CPU_SET timeout $TEST_DURATION \
        "$BASE_DIR/examples/hotstuff-client" \
        --idx $CLIENT_ID \
        --iter -1 \
        --max-async $CLIENT_ASYNC \
        --clinworker $CLI_NWORKER \
        --cliburst $CLI_BURST \
        --max-cli-msg 4194304 \
        2>&1 | grep "hotstuff info" > "client${CLIENT_ID}.log" &
    CLIENT_PIDS[$i]=$!
    echo "    PID: ${CLIENT_PIDS[$i]}"
done

# 6. 等待客户端完成
echo "等待客户端测试完成（${TEST_DURATION}s）..."
sleep $((TEST_DURATION + 5))

# 7. 停止所有进程
echo "停止所有进程..."
pkill -9 -f hotstuff-app 2>/dev/null || true
pkill -9 -f hotstuff-client 2>/dev/null || true
kill $MONITOR_PID 2>/dev/null || true

# 8. 分析日志
echo "分析测试结果..."
echo "--------------------------------"

# 合并客户端日志
cat client*.log > client_total.log 2>/dev/null

if [ -f client_total.log ] && [ -s client_total.log ]; then
    TOTAL_COMMITS=$(wc -l < client_total.log)
    echo "总提交记录数: $TOTAL_COMMITS"
    
    if [ "$TOTAL_COMMITS" -gt 0 ]; then
        # 计算TPS（每秒交易数）
        TPS=$((TOTAL_COMMITS * BLOCK_SIZE / TEST_DURATION))
        echo "估算TPS: $TPS"
        
        # 显示副本0的日志尾部
        echo "副本0日志尾部:"
        tail -n 10 log0
        
        # 使用性能分析脚本
        echo "性能指标分析:"
        if [ -f "$BASE_DIR/scripts/thr_hist.py" ]; then
            python3 "$BASE_DIR/scripts/thr_hist.py" < client_total.log
        else
            echo "警告: thr_hist.py脚本未找到"
        fi
        
        # 显示性能监控摘要
        echo "性能监控摘要:"
        if [ -f perf_stats.log ]; then
            echo "监控数据已保存到: perf_stats.log"
            tail -n 5 perf_stats.log
        fi
    else
        echo "错误: 没有交易被提交"
        echo "检查副本日志..."
        for i in {0..4}; do
            echo "log$i 最后10行:"
            tail -n 10 "log$i"
            echo "---"
        done
    fi
else
    echo "错误: client_total.log文件未生成或为空"
    echo "检查副本日志中的错误..."
    tail -n 50 log0
fi

echo "================================================"
echo "测试完成"
echo "配置文件:"
echo "  repburst=$REP_BURST, cliburst=$CLI_BURST"
echo "  nworker=$N_WORKER, repnworker=$REP_NWORKER, clinworker=$CLI_NWORKER"
echo "  max-async=$MAX_ASYNC (每个客户端: $CLIENT_ASYNC)"
echo "================================================"