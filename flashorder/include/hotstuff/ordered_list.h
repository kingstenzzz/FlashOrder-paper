/**
 * Copyright 2018 VMware
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * 
 *          FlashOrder - 基于 HyperOrder-X 的公平排序
 */

#ifndef _FLASHORDER_ORDERED_LIST_H
#define _FLASHORDER_ORDERED_LIST_H

#include <algorithm>
#include <numeric>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include "salticidae/stream.h"
#include "hotstuff/util.h"

namespace hotstuff {

/**
 * OrderedList — FlashOrder 所需的副本本地排序结构体。
 * 每个副本收到一批交易后，按本地接收时间戳排序，
 * 将 cmds（交易哈希）和 timestamps（微秒级时间戳）打包发给 Leader。
 * FlashOrder 的 HyperGraph::finalize() 直接消费此结构。
 */
struct OrderedList {
    std::vector<uint256_t> cmds;         // 交易哈希，按本地时间戳排序
    std::vector<uint64_t>  timestamps;   // 对应每笔交易的本地接收时间戳（微秒）

    OrderedList() = default;

    /** 按 timestamps 升序对 cmds 和 timestamps 同步排序 */
    void sort_cmds() {
        if (cmds.size() != timestamps.size() || cmds.size() <= 1)
            return;
        // 构建索引数组并按 timestamp 排序
        std::vector<size_t> idx(cmds.size());
        std::iota(idx.begin(), idx.end(), 0);
        std::sort(idx.begin(), idx.end(), [this](size_t a, size_t b) {
            return timestamps[a] < timestamps[b];
        });
        // 根据排好序的索引重排 cmds 和 timestamps
        std::vector<uint256_t> sorted_cmds(cmds.size());
        std::vector<uint64_t>  sorted_ts(timestamps.size());
        for (size_t i = 0; i < idx.size(); i++) {
            sorted_cmds[i] = cmds[idx[i]];
            sorted_ts[i]   = timestamps[idx[i]];
        }
        cmds = std::move(sorted_cmds);
        timestamps = std::move(sorted_ts);
    }
};

/**
 * SeenOrderTracker — 跟踪已"看到"（received）但尚未被 propose/execute 的交易。
 * 替代 Themis 中基于双向链表的 OrderedList 用于 local_order_seen_*_cache。
 */
class SeenOrderTracker {
    std::unordered_set<uint256_t> seen;

    public:
    SeenOrderTracker() = default;

    void add(const uint256_t &cmd) { seen.insert(cmd); }
    void remove(const uint256_t &cmd) { seen.erase(cmd); }
    bool contains(const uint256_t &cmd) const { return seen.count(cmd) > 0; }
    size_t size() const { return seen.size(); }

    std::vector<uint256_t> get_cmds() const {
        return std::vector<uint256_t>(seen.begin(), seen.end());
    }
};

}
#endif