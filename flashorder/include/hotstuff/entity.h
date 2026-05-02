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
 */

#ifndef _HOTSTUFF_ENT_H
#define _HOTSTUFF_ENT_H

#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <string>
#include <cstddef>
#include <ios>
#include <queue>
#include <deque>

#include "salticidae/netaddr.h"
#include "salticidae/ref.h"
#include "hotstuff/type.h"
#include "hotstuff/util.h"
#include "hotstuff/crypto.h"
#include "hotstuff/ordered_list.h"

namespace hotstuff {

// FlashOrder: 不再需要 bitpacked adjacency matrix 的最大尺寸限制
// #define MAX_PROPOSAL_SIZE_SUPPORTED 960

enum EntityType {
    ENT_TYPE_CMD = 0x0,
    ENT_TYPE_BLK = 0x1
};

struct ReplicaInfo {
    ReplicaID id;
    salticidae::PeerId peer_id;
    pubkey_bt pubkey;

    ReplicaInfo(ReplicaID id,
                const salticidae::PeerId &peer_id,
                pubkey_bt &&pubkey):
        id(id), peer_id(peer_id), pubkey(std::move(pubkey)) {}

    ReplicaInfo(const ReplicaInfo &other):
        id(other.id), peer_id(other.peer_id),
        pubkey(other.pubkey->clone()) {}

    ReplicaInfo(ReplicaInfo &&other):
        id(other.id), peer_id(other.peer_id),
        pubkey(std::move(other.pubkey)) {}
};

class ReplicaConfig {
    std::unordered_map<ReplicaID, ReplicaInfo> replica_map;

    public:
    size_t nreplicas;
    size_t nmajority;
    double fairness_parameter;      // FlashOrder: gamma parameter

    double solid_tx_threshold;      // FlashOrder: 保留用于兼容性
    double non_blank_tx_threshold;  // FlashOrder
    double tx_edge_threshold;       // FlashOrder

    double gen_param;               // FlashOrder-D: 交易生成间隔 (ms), 0=自动检测
    double network_param;           // FlashOrder-D: 网络延迟期望 (ms), 0=自动检测
    
    bool auto_param;               // FlashOrder-D: 是否自动检测参数

    ReplicaConfig(): nreplicas(0), 
                        nmajority(0), 
                        fairness_parameter(1),
                        solid_tx_threshold(0),
                        non_blank_tx_threshold(0),
                        tx_edge_threshold(0),
                        gen_param(0.0),
                        network_param(0.0),
                        auto_param(true) {}

    void add_replica(ReplicaID rid, const ReplicaInfo &info) {
        replica_map.insert(std::make_pair(rid, info));
        nreplicas++;
    }

    const ReplicaInfo &get_info(ReplicaID rid) const {
        auto it = replica_map.find(rid);
        if (it == replica_map.end())
            throw HotStuffError("rid %s not found",
                    get_hex(rid).c_str());
        return it->second;
    }

    const PubKey &get_pubkey(ReplicaID rid) const {
        return *(get_info(rid).pubkey);
    }

    const salticidae::PeerId &get_peer_id(ReplicaID rid) const {
        return get_info(rid).peer_id;
    }
};

class Block;
class HotStuffCore;

using block_t = salticidae::ArcObj<Block>;

class Command: public Serializable {
    friend HotStuffCore;
    public:
    virtual ~Command() = default;
    virtual const uint256_t &get_hash() const = 0;
    virtual bool verify() const = 0;
    virtual operator std::string () const {
        DataStream s;
        s << "<cmd id=" << get_hex10(get_hash()) << ">";
        return s;
    }
};

using command_t = ArcObj<Command>;

template<typename Hashable>
inline static std::vector<uint256_t>
get_hashes(const std::vector<Hashable> &plist) {
    std::vector<uint256_t> hashes;
    for (const auto &p: plist)
        hashes.push_back(p->get_hash());
    return hashes;
}

class Block {
    friend HotStuffCore;
    std::vector<uint256_t> parent_hashes;
    std::vector<uint256_t> cmds;                                                // FlashOrder: 线性交易排序列表
    quorum_cert_bt qc;
    bytearray_t extra;

    /* the following fields can be derived from above */
    uint256_t hash;
    std::vector<block_t> parents;
    block_t qc_ref;
    quorum_cert_bt self_qc;
    uint32_t height;
    bool delivered;
    int8_t decision;

    std::unordered_set<ReplicaID> voted;

    public:
    Block():
        qc(nullptr),
        qc_ref(nullptr),
        self_qc(nullptr), height(0),
        delivered(false), decision(0) {}

    Block(bool delivered, int8_t decision):
        qc(new QuorumCertDummy()),
        hash(salticidae::get_hash(*this)),
        qc_ref(nullptr),
        self_qc(nullptr), height(0),
        delivered(delivered), decision(decision) {}

    Block(const std::vector<block_t> &parents,
        const std::vector<uint256_t> &cmds,                                     // FlashOrder
        quorum_cert_bt &&qc,
        bytearray_t &&extra,
        uint32_t height,
        const block_t &qc_ref,
        quorum_cert_bt &&self_qc,
        int8_t decision = 0):
            parent_hashes(get_hashes(parents)),
            cmds(cmds),                                                         // FlashOrder
            qc(std::move(qc)),
            extra(std::move(extra)),
            hash(salticidae::get_hash(*this)),
            parents(parents),
            qc_ref(qc_ref),
            self_qc(std::move(self_qc)),
            height(height),
            delivered(0),
            decision(decision) {}

    void serialize(DataStream &s) const;

    void unserialize(DataStream &s, HotStuffCore *hsc);

    // FlashOrder: 获取线性排序结果
    const std::vector<uint256_t> &get_cmds() const {
        return cmds;
    }

    const std::vector<block_t> &get_parents() const {
        return parents;
    }

    const std::vector<uint256_t> &get_parent_hashes() const {
        return parent_hashes;
    }

    const uint256_t &get_hash() const { return hash; }

    bool verify(const HotStuffCore *hsc) const;

    promise_t verify(const HotStuffCore *hsc, VeriPool &vpool) const;

    int8_t get_decision() const { return decision; }

    bool is_delivered() const { return delivered; }

    uint32_t get_height() const { return height; }

    const quorum_cert_bt &get_qc() const { return qc; }

    const block_t &get_qc_ref() const { return qc_ref; }

    const bytearray_t &get_extra() const { return extra; }

    operator std::string () const {
        DataStream s;
        s << "<block "
          << "id="  << get_hex10(hash) << " "
          << "height=" << std::to_string(height) << " "
          << "parent=" << get_hex10(parent_hashes[0]) << " "
          << "qc_ref=" << (qc_ref ? get_hex10(qc_ref->get_hash()) : "null") << ">";
        return s;
    }
};

struct BlockHeightCmp {
    bool operator()(const block_t &a, const block_t &b) const {
        return a->get_height() < b->get_height();
    }
};

class EntityStorage {
    std::unordered_map<const uint256_t, block_t> blk_cache;
    std::unordered_map<const uint256_t, command_t> cmd_cache;
    /** FlashOrder: 缓存每个副本的 OrderedList（包含 cmds + timestamps） */
    std::unordered_map<ReplicaID, std::deque<OrderedList>> ordered_list_cache;
    /** FlashOrder: 跟踪已 propose / 已 execute 的交易 */
    SeenOrderTracker seen_propose_level;
    SeenOrderTracker seen_execute_level;
    std::unordered_set<uint256_t> proposed_cmds_cache;

    public:
    EntityStorage() = default;

    bool is_blk_delivered(const uint256_t &blk_hash) {
        auto it = blk_cache.find(blk_hash);
        if (it == blk_cache.end()) return false;
        return it->second->is_delivered();
    }

    bool is_blk_fetched(const uint256_t &blk_hash) {
        return blk_cache.count(blk_hash);
    }

    block_t add_blk(Block &&_blk, const ReplicaConfig &/*config*/) {
        block_t blk = new Block(std::move(_blk));
        return blk_cache.insert(std::make_pair(blk->get_hash(), blk)).first->second;
    }

    const block_t &add_blk(const block_t &blk) {
        return blk_cache.insert(std::make_pair(blk->get_hash(), blk)).first->second;
    }

    block_t find_blk(const uint256_t &blk_hash) {
        auto it = blk_cache.find(blk_hash);
        return it == blk_cache.end() ? nullptr : it->second;
    }

    bool is_cmd_fetched(const uint256_t &cmd_hash) {
        return cmd_cache.count(cmd_hash);
    }

    const command_t &add_cmd(const command_t &cmd) {
        return cmd_cache.insert(std::make_pair(cmd->get_hash(), cmd)).first->second;
    }

    command_t find_cmd(const uint256_t &cmd_hash) {
        auto it = cmd_cache.find(cmd_hash);
        return it == cmd_cache.end() ? nullptr: it->second;
    }

    size_t get_cmd_cache_size() {
        return cmd_cache.size();
    }
    size_t get_blk_cache_size() {
        return blk_cache.size();
    }

    bool try_release_cmd(const command_t &cmd) {
        if (cmd.get_cnt() == 2) /* only referred by cmd and the storage */
        {
            const auto &cmd_hash = cmd->get_hash();
            cmd_cache.erase(cmd_hash);
            return true;
        }
        return false;
    }

    bool try_release_blk(const block_t &blk) {
        if (blk.get_cnt() == 2) /* only referred by blk and the storage */
        {
            const auto &blk_hash = blk->get_hash();
#ifdef HOTSTUFF_PROTO_LOG
            HOTSTUFF_LOG_INFO("releasing blk %.10s", get_hex(blk_hash).c_str());
#endif
            blk_cache.erase(blk_hash);
            return true;
        }
#ifdef HOTSTUFF_PROTO_LOG
        else
            HOTSTUFF_LOG_INFO("cannot release (%lu)", blk.get_cnt());
#endif
        return false;
    }

    // ====== FlashOrder: 本地排序缓存管理 ======

    /** 添加一个副本发来的 OrderedList */
    void add_local_order(ReplicaID rid, const OrderedList &olist) {
        // 只保留尚未 propose 的交易
        OrderedList filtered;
        for (size_t i = 0; i < olist.cmds.size(); i++) {
            if (!is_cmd_proposed(olist.cmds[i])) {
                filtered.cmds.push_back(olist.cmds[i]);
                if (i < olist.timestamps.size())
                    filtered.timestamps.push_back(olist.timestamps[i]);
            }
        }
        if (!filtered.cmds.empty()) {
            ordered_list_cache[rid].push_back(std::move(filtered));
        }
    }

    /** 获取当前已收到多少个副本的本地排序 */
    size_t get_local_order_cache_size() {
        return ordered_list_cache.size();
    }

    /** 获取所有缓存了本地排序的副本 ID 列表 */
    std::vector<ReplicaID> get_ordered_list_replica_vector() {
        std::vector<ReplicaID> replicas;
        for (auto const &entry : ordered_list_cache) {
            replicas.push_back(entry.first);
        }
        return replicas;
    }

    /** 获取指定副本队列最前面的 OrderedList */
    const OrderedList &get_front_ordered_list(ReplicaID rid) {
        return ordered_list_cache[rid].front();
    }

    /** 弹出指定副本队列最前面的 OrderedList */
    void pop_front_ordered_list(ReplicaID rid) {
        ordered_list_cache[rid].pop_front();
        if (ordered_list_cache[rid].empty()) {
            ordered_list_cache.erase(rid);
        }
    }

    /** 收集所有副本的 front OrderedList 到一个 vector 中，供 FlashOrder 使用 */
    std::vector<OrderedList> collect_ordered_lists() {
        std::vector<OrderedList> result;
        for (auto &entry : ordered_list_cache) {
            if (!entry.second.empty()) {
                result.push_back(entry.second.front());
            }
        }
        return result;
    }

    /** 弹出所有副本的 front OrderedList */
    void pop_all_front_ordered_lists() {
        std::vector<ReplicaID> to_erase;
        for (auto &entry : ordered_list_cache) {
            entry.second.pop_front();
            if (entry.second.empty()) {
                to_erase.push_back(entry.first);
            }
        }
        for (auto rid : to_erase) {
            ordered_list_cache.erase(rid);
        }
    }

    // ====== Seen 交易跟踪 ======

    void update_local_order_seen(const std::vector<uint256_t> &cmds) {
        for (const auto &cmd : cmds) {
            seen_propose_level.add(cmd);
            seen_execute_level.add(cmd);
        }
    }

    void remove_local_order_seen_execute_level(const uint256_t &cmd) {
        seen_execute_level.remove(cmd);
    }

    void remove_local_order_seen_propose_level(const uint256_t &cmd) {
        seen_propose_level.remove(cmd);
    }

    // ====== Proposed 交易缓存 ======

    void add_to_proposed_cmds_cache(const uint256_t &cmd) {
        proposed_cmds_cache.insert(cmd);
    }

    void remove_from_proposed_cmds_cache(const uint256_t &cmd) {
        proposed_cmds_cache.erase(cmd);
    }

    bool is_cmd_proposed(const uint256_t &cmd) {
        return proposed_cmds_cache.count(cmd) > 0;
    }

};

}

#endif
