// FlashOrder vs Themis Sorting Benchmark
#include <iostream>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <chrono>
#include <random>
#include <algorithm>
#include <cstring>
#include <cmath>
#include <iomanip>
#include "hotstuff/flashorder.h"
#include "hotstuff/graph.h"

using namespace hotstuff;
using namespace FlashOrder;

#define LOG_INFO std::cout
#define LOG_PERF std::cout

struct BenchmarkResult {
    double total_time_ms;
    int n_hyperedges;
    double avg_hyperedge_size;
    std::vector<uint256_t> result;
};

struct ThemBenchmarkResult {
    double total_time_ms;
    int n_sccs;
    std::vector<uint256_t> result;
};

std::vector<OrderedList> generate_random_orderings(int n_nodes, int n_txns, uint32_t seed) {
    std::mt19937 rng(seed);
    std::vector<OrderedList> orderings(n_nodes);
    
    for (int r = 0; r < n_nodes; r++) {
        orderings[r].cmds.reserve(n_txns);
        orderings[r].timestamps.reserve(n_txns);
        
        std::vector<int> indices(n_txns);
        std::iota(indices.begin(), indices.end(), 0);
        std::shuffle(indices.begin(), indices.end(), rng);
        
        for (int i = 0; i < n_txns; i++) {
            uint256_t cmd;
            memset(&cmd, indices[i], sizeof(cmd));
            orderings[r].cmds.push_back(cmd);
            orderings[r].timestamps.push_back(i * 100);
        }
    }
    return orderings;
}

std::vector<std::vector<uint256_t>> convert_to_vectors(const std::vector<OrderedList>& orderings) {
    std::vector<std::vector<uint256_t>> result;
    for (const auto& ol : orderings) {
        result.push_back(ol.cmds);
    }
    return result;
}

ThemBenchmarkResult themis_benchmark(const std::vector<std::vector<uint256_t>>& orderings,
                                      int n_nodes, int n_faulty, double fairness_param) {
    ThemBenchmarkResult res;
    auto start = std::chrono::steady_clock::now();
    
    int n_txns = orderings[0].size();
    std::unordered_map<uint256_t, std::unordered_set<uint256_t>> graph;
    std::unordered_map<uint256_t, int> cmd_to_id;
    std::vector<uint256_t> id_to_cmd;
    
    for (const auto& ol : orderings) {
        for (size_t i = 0; i < ol.size(); i++) {
            if (cmd_to_id.find(ol[i]) == cmd_to_id.end()) {
                cmd_to_id[ol[i]] = id_to_cmd.size();
                id_to_cmd.push_back(ol[i]);
            }
        }
    }
    
    for (const auto& ol : orderings) {
        for (size_t i = 0; i < ol.size(); i++) {
            for (size_t j = i + 1; j < ol.size(); j++) {
                graph[ol[i]].insert(ol[j]);
            }
        }
    }
    
    if (graph.empty()) {
        res.total_time_ms = 0;
        res.n_sccs = 0;
        return res;
    }
    
    CondensationGraph condgraph(graph);
    auto sccs = condgraph.get_condensation_graph();
    
    res.result.clear();
    for (const auto& scc : sccs) {
        for (const auto& cmd : scc) {
            res.result.push_back(cmd);
        }
    }
    
    res.n_sccs = sccs.size();
    
    auto end = std::chrono::steady_clock::now();
    res.total_time_ms = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count() / 1000.0;
    
    return res;
}

BenchmarkResult flashorder_benchmark(std::vector<OrderedList>& orderings,
                                      int n_faulty, int n_nodes, double gamma,
                                      double gen_param = 100.0, double network_param = 100.0) {
    BenchmarkResult res;
    auto start = std::chrono::steady_clock::now();
    
    HyperGraph<10000> hg;
    auto result = hg.finalize(orderings, n_faulty, n_nodes, gamma, gen_param, network_param);
    
    auto end = std::chrono::steady_clock::now();
    res.total_time_ms = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count() / 1000.0;
    res.result = result;
    
    res.n_hyperedges = 0;
    res.avg_hyperedge_size = 0;
    
    return res;
}

void print_separator() {
    std::cout << "============================================================\n";
}

void run_benchmark(int n_nodes, int n_txns, int n_faulty, double gamma, uint32_t seed) {
    std::cout << "\n--- Benchmark: nodes=" << n_nodes << " txns=" << n_txns 
              << " f=" << n_faulty << " gamma=" << gamma << " seed=" << seed << " ---\n";
    
    auto orderings = generate_random_orderings(n_nodes, n_txns, seed);
    auto orderings_copy = orderings;
    
    std::cout << "Running Themis benchmark...\n";
    auto them_res = themis_benchmark(convert_to_vectors(orderings), n_nodes, n_faulty, gamma);
    std::cout << "  Themis: " << them_res.n_sccs << " SCCs, time=" 
              << std::fixed << std::setprecision(3) << them_res.total_time_ms << " ms\n";
    
    std::cout << "Running FlashOrder benchmark...\n";
    auto fo_res = flashorder_benchmark(orderings_copy, n_faulty, n_nodes, gamma);
    std::cout << "  FlashOrder: time=" << fo_res.total_time_ms << " ms\n";
    
    std::cout << "\nSpeedup: " << std::fixed << std::setprecision(2) 
              << (them_res.total_time_ms / fo_res.total_time_ms) << "x\n";
}

int main(int argc, char** argv) {
    std::cout << "=== FlashOrder vs Themis Sorting Benchmark ===\n";
    print_separator();
    
    std::vector<std::tuple<int, int, int, double, uint32_t>> test_cases = {
        {4, 50, 1, 0.75, 42},
        {4, 100, 1, 0.75, 42},
        {4, 200, 1, 0.75, 42},
        {4, 500, 1, 0.75, 42},
        {4, 1000, 1, 0.75, 42},
        {9, 50, 3, 0.75, 42},
        {9, 100, 3, 0.75, 42},
        {9, 200, 3, 0.75, 42},
        {9, 500, 3, 0.75, 42},
        {9, 1000, 3, 0.75, 42},
    };
    
    for (const auto& tc : test_cases) {
        int n_nodes, n_txns, n_faulty;
        double gamma;
        uint32_t seed;
        std::tie(n_nodes, n_txns, n_faulty, gamma, seed) = tc;
        run_benchmark(n_nodes, n_txns, n_faulty, gamma, seed);
    }
    
    print_separator();
    std::cout << "=== Benchmark Complete ===\n";
    
    return 0;
}
