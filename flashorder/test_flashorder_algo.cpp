// 简单的 FlashOrder 算法测试
#include <iostream>
#include <vector>
#include <cstdint>
#include "hotstuff/flashorder.h"

int main() {
    std::cout << "=== FlashOrder 算法测试 ===\n";
    
    // 创建测试数据
    std::vector<hotstuff::OrderedList> ordered_lists;
    
    // 模拟 3 个副本的排序列表
    for (int r = 0; r < 3; r++) {
        hotstuff::OrderedList olist;
        
        // 每个副本有 5 个交易
        for (int i = 0; i < 5; i++) {
            uint256_t cmd;
            // 创建简单的交易哈希（实际中应该是真实的哈希）
            memset(&cmd, r * 10 + i, sizeof(cmd));
            olist.cmds.push_back(cmd);
            olist.timestamps.push_back(1000 * r + i * 100); // 模拟时间戳
        }
        
        ordered_lists.push_back(olist);
    }
    
    std::cout << "创建了 " << ordered_lists.size() << " 个副本的 OrderedList\n";
    
    // 测试 HyperGraph
    try {
        FlashOrder::HyperGraph<100> hg;
        int nfaulty = 1; // 假设 1 个故障节点
        int nnodes = 3;  // 3 个节点
        double gamma = 1.0; // fairness 参数
        
        std::vector<uint256_t> final_order = hg.finalize(ordered_lists, nfaulty, nnodes, gamma);
        
        std::cout << "FlashOrder 算法成功执行！\n";
        std::cout << "最终排序包含 " << final_order.size() << " 个交易\n";
        
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "错误: " << e.what() << "\n";
        return 1;
    }
}