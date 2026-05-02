#!/bin/bash

echo "=== FlashOrder 集成测试 ==="
echo "1. 清理环境..."
pkill -9 -f hotstuff-app 2>/dev/null || true
pkill -9 -f hotstuff-client 2>/dev/null || true
rm -f log*.log client.log

echo "2. 生成配置..."
printf '127.0.0.1\n%.0s' {1..4} > _ips_tmp.txt
python3 scripts/gen_conf.py --prefix hotstuff --ips _ips_tmp.txt --keygen ./hotstuff-keygen --tls-keygen ./hotstuff-tls-keygen --nodes nodes.txt --block-size 10 --pace-maker rr --nworker 4 --repnworker 4 --clinworker 2 --repburst 100 --cliburst 100

echo "3. 启动4个副本..."
for i in {0..3}; do
    echo "  启动副本 $i..."
    ./build/examples/flashorder-app --conf hotstuff-sec${i}.conf > log${i}.log 2>&1 &
    REPLICA_PIDS[$i]=$!
    sleep 0.5
done

echo "4. 等待副本初始化（5秒）..."
sleep 5

echo "5. 检查副本状态..."
for i in {0..3}; do
    if ps -p ${REPLICA_PIDS[$i]} > /dev/null; then
        echo "  副本 $i (PID: ${REPLICA_PIDS[$i]}) 运行中"
        echo "  最后几行日志:"
        tail -5 log${i}.log 2>/dev/null || echo "    无日志"
    else
        echo "  副本 $i 已停止"
        echo "  错误日志:"
        tail -20 log${i}.log 2>/dev/null || echo "    无日志"
    fi
done

echo "6. 启动客户端测试（10秒）..."
timeout 10 ./build/examples/flashorder-client --idx 0 --iter 100 --max-async 10 > client_raw.log 2>&1

echo "7. 提取 benchmark 数据..."
grep "hotstuff info" client_raw.log > client.log

echo "8. 检查 benchmark 数据..."
if [ -s client.log ]; then
    echo "  client.log 内容:"
    cat client.log
    echo ""
    echo "  运行 thr_hist.py 分析..."
    python3 scripts/thr_hist.py < client.log 2>&1 || echo "  分析失败"
else
    echo "  无 benchmark 数据"
    echo "  client_raw.log 最后几行:"
    tail -20 client_raw.log
fi

echo "9. 停止副本..."
for i in {0..3}; do
    kill ${REPLICA_PIDS[$i]} 2>/dev/null || true
done

echo "=== 测试完成 ==="