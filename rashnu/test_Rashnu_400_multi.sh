#!/bin/bash
cd /home/kkk/code/Order-Fairness/Rashnu
pkill -9 -f hotstuff || true
rm -f client*.log log0 log1 log2 log3

./examples/hotstuff-app --conf ./hotstuff-sec0.conf > log0 2>&1 &
./examples/hotstuff-app --conf ./hotstuff-sec1.conf > log1 2>&1 &
./examples/hotstuff-app --conf ./hotstuff-sec2.conf > log2 2>&1 &
./examples/hotstuff-app --conf ./hotstuff-sec3.conf > log3 2>&1 &

sleep 10

echo "Running 4 clients for 40 seconds..."
timeout 40 ./examples/hotstuff-client --idx 0 --iter -1 --max-async 800 2>&1 | grep "hotstuff info" > client0.log &
timeout 40 ./examples/hotstuff-client --idx 0 --iter -1 --max-async 800 2>&1 | grep "hotstuff info" > client1.log &
timeout 40 ./examples/hotstuff-client --idx 0 --iter -1 --max-async 800 2>&1 | grep "hotstuff info" > client2.log &
timeout 40 ./examples/hotstuff-client --idx 0 --iter -1 --max-async 800 2>&1 | grep "hotstuff info" > client3.log &

sleep 45

pkill -9 -f hotstuff
cat client*.log > client_out.log
echo "Total client log lines: $(wc -l < client_out.log)"
python3 scripts/thr_hist.py < client_out.log
