#!/bin/bash

# Configuration
TEST_DIR="/home/kkk/code/Order-Fairness/Rashnu"
CLIENT_EXE="$TEST_DIR/examples/hotstuff-client"
REPLICA_EXE="$TEST_DIR/examples/hotstuff-app"
THR_HIST="$TEST_DIR/scripts/thr_hist.py"
RESULT_FILE="$TEST_DIR/result/summary.csv"

cd $TEST_DIR

# Initialize result file
echo "clients,throughput,latency_ms" > $RESULT_FILE

echo "Starting batch tests for 4, 8, and 16 clients..."
echo "------------------------------------------------"

for n_clients in 4 8 16; do
    echo "Testing with $n_clients clients..."
    
    # 1. Cleanup old processes and logs
    pkill -9 -f hotstuff || true
    pkill -9 -f hotstuff-app || true
    pkill -9 -f hotstuff-client || true
    rm -f log* client*.log client_total.log
    
    # 2. Start 4 replicas
    for i in {0..3}; do
        $REPLICA_EXE --conf $TEST_DIR/hotstuff-sec$i.conf > log$i 2>&1 &
    done
    
    # Wait for replicas to elect a leader and stabilize
    echo "  Waiting for replicas to start (10s)..."
    sleep 20
    
    # 3. Start $n_clients clients
    echo "  Starting $n_clients clients for 60 seconds..."
    for i in $(seq 1 $n_clients); do
        # We use --max-async 200 as it was reported stable by the user
        timeout 60 $CLIENT_EXE --idx 0 --iter -1 --max-async 200 2>&1 | grep "hotstuff info" > client$i.log &
    done
    
    # Wait for clients to finish (timeout 60 + buffer)
    sleep 65
    
    # 4. Force stop everything
    pkill -9 -f hotstuff-app || true
    pkill -9 -f hotstuff-client || true
    
    # 5. Analyze results
    cat client*.log > client_total.log
    total_lines=$(wc -l < client_total.log)
    
    if [ "$total_lines" -gt 10 ]; then
        # Run thr_hist.py and extract metrics
        output=$(python3 $THR_HIST < client_total.log 2>/dev/null)
        
        # Extract average throughput from the values list [v1, v2, ...]
        # We remove first and last 5 seconds to get "steady state" if possible, 
        # but for simplicity we just average all non-zero values.
        thr=$(echo "$output" | head -n 1 | sed 's/[\[\]]//g' | tr ',' '\n' | awk '$1 > 0 { sum += $1; n++ } END { if (n > 0) print sum / n; else print 0 }')
        
        # Extract latency (using the second "lat =" which is post-outlier removal)
        lat=$(echo "$output" | grep "lat =" | tail -n 1 | awk '{print $3}' | sed 's/ms//')
        
        if [ -z "$thr" ]; then thr=0; fi
        if [ -z "$lat" ]; then lat=0; fi
        
        echo "$n_clients,$thr,$lat" >> $RESULT_FILE
        printf "  Done. Throughput: %.2f tx/s, Latency: %s ms\n" "$thr" "$lat"
    else
        echo "$n_clients,0,0" >> $RESULT_FILE
        echo "  Done. FAILED (No commit logs found)"
    fi
    echo "------------------------------------------------"
done

echo "Batch test completed."
echo "Summary table (saved to $RESULT_FILE):"
cat $RESULT_FILE

# Also generate a markdown table for the user
echo ""
echo "### Performance Summary Table"
echo "| Clients | Throughput (tx/s) | Latency (ms) |"
echo "|---------|-------------------|--------------|"
awk -F',' 'NR > 1 { printf "| %s | %.2f | %s |\n", $1, $2, $3 }' $RESULT_FILE
