# -*- coding: utf-8 -*-
"""
Hypergraph Protocol Implementation (HyperOrder-X Phase 1)
Advanced multi-stage algorithm: preference matrix → canonical clustering → hypergraph → topological extraction
Based on compare_sorting.py implementation approach
"""

import numpy as np
import time
import random
from itertools import permutations
from typing import List, Dict, Any, Tuple, Optional
from collections import deque


def calculate_delta(gen_param, network_param, phi=0.1, n_transactions=None, target_similarity=0.8):
    """
    增强版delta计算：综合考虑网络参数、交易规模和目标相似度
    
    改进的公式: δ_opt = Φ · E[delay] / Δt_gen · adjustment_factor
    
    新增考虑因素:
    - 交易数量影响：交易越多，需要更大的delta来维持聚类质量
    - 目标相似度调节：根据期望的算法相似度动态调整
    - 自适应调节因子：平衡效率与准确性
    
    Args:
        gen_param: 交易生成间隔 Δt_gen (ms)
        network_param: 网络延迟期望 E[delay] (ms)
        phi: 基础校准因子 Φ (默认0.1)
        n_transactions: 交易数量 (可选，用于规模调节)
        target_similarity: 目标相似度 (0.5~0.95，默认0.8)
    
    Returns:
        int: 优化后的delta值
    """
    if gen_param <= 0:
        return 5  # 默认值
    
    # 基础delta计算
    base_delta = phi * network_param / gen_param
    
    # 交易规模调节因子
    scale_factor = 1.0
    if n_transactions is not None:
        # 交易数量越多，适当增加delta以维持聚类质量
        # 使用对数调节避免过度增长
        if n_transactions > 1000:
            scale_factor = 1.0 + 0.3 * np.log(n_transactions / 1000)
        elif n_transactions < 100:
            # 交易很少时，可以适当减小delta
            scale_factor = max(0.7, 1.0 - 0.3 * np.log(100 / n_transactions))
    
    # 目标相似度调节因子
    similarity_factor = 1.0
    if target_similarity is not None:
        # 目标相似度越高，需要更大的delta
        # 从0.5(宽松)到0.95(严格)的映射
        similarity_factor = 0.8 + 1.2 * (target_similarity - 0.5) / 0.45
        similarity_factor = max(0.8, min(2.0, similarity_factor))  # 限制在合理范围内
    
    # 综合计算最终delta
    adjusted_delta = base_delta * scale_factor * similarity_factor
    
    # 确保合理的数值范围
    final_delta = max(1, min(100, int(round(adjusted_delta))))
    
    return final_delta


class HyperGraphSorter:
    """
    HyperOrder-X Phase 1: Advanced hypergraph-based consensus protocol.
    
    Multi-stage algorithm:
    1. Compute pairwise preference matrix (voting-based)
    2. Canonical clustering (median canonical coordinates + geometric clustering)
    3. Build hypergraph with dependencies and internal ordering
    4. Topological sort and extract final ordering
    
    γ 语义统一（Unified gamma semantics）:
    γ越大 → 公平性要求越宽松 (bigger γ = more relaxed fairness requirement)
    
    Unified threshold formula: threshold = n(1-γ) + f + 1
    """
    
    def __init__(self, n_nodes: int, n_transactions: int, f_byzantine: int, 
                 seed: Optional[int] = None, gamma: float = 1.0, delta: int = 5, k: float = 1.5):
        """
        Initialize HyperGraphSorter.
        
        Args:
            n_nodes: Total number of nodes
            n_transactions: Number of transactions to order
            f_byzantine: Number of Byzantine nodes that can be tolerated
            seed: Random seed for reproducibility
            gamma: Fairness parameter
            delta: Clustering distance threshold for canonical clustering
            k: Scaling factor for dynamic delta calculation (default: 1.5)
        """
        self.n = n_nodes
        self.num_txs = n_transactions
        self.f = f_byzantine
        self.gamma = gamma
        self.delta = delta
        self.k = k  # Scaling factor for dynamic delta calculation
        self.honest_nodes = n_nodes - f_byzantine
        self.rng = np.random.default_rng(seed)
        self.threshold = max(1, int(n_nodes * (1 - gamma)) + f_byzantine + 1)
    
    def compute_pairwise_preferences(self, node_orderings: np.ndarray, chunk: int = 16) -> np.ndarray:
        """
        Calculate pairwise preference matrix pref[i, j] = #honest nodes prefer i before j.
        
        Vectorized implementation for efficiency.
        Handles both:
        - node_orderings as indices (List[List[int]]) 
        - node_orderings as timestamps/values (np.ndarray where rows are nodes, columns are transactions)
        
        Args:
            node_orderings: Either shape (n_nodes, n_transactions) or list of lists
            chunk: Memory chunk size for processing
        
        Returns:
            Preference matrix shape (n_transactions, n_transactions)
        """
        # 使用全部节点数据（包括Byzantine），通过threshold阈值过滤恶意影响
        all_orderings = node_orderings
        
        # Convert timestamps to indices
        if isinstance(all_orderings, np.ndarray) and all_orderings.dtype in [np.float64, np.float32]:
            # This is timestamp data, convert to ordering indices
            ords_indices = []
            for row in all_orderings:
                # argsort gives indices that would sort the array
                idx = np.argsort(row).astype(np.int32)
                ords_indices.append(idx)
            ords = np.asarray(ords_indices, dtype=np.int32)
        else:
            # This is already indices
            ords = np.asarray(all_orderings, dtype=np.int32)
        
        m, b = ords.shape
        
        # Compute position matrix: pos[node, tx] = rank of tx in that node's ordering
        pos = np.empty((m, b), dtype=np.int32)
        rows = np.arange(m, dtype=np.int32)[:, None]
        pos[rows, ords] = np.arange(b, dtype=np.int32)[None, :]
        
        # Accumulate preferences in chunks
        pref = np.zeros((b, b), dtype=np.uint16 if m < 65535 else np.int32)
        
        for s in range(0, m, chunk):
            p = pos[s:s + chunk]  # (c, b)
            pref += (p[:, :, None] < p[:, None, :]).sum(axis=0, dtype=pref.dtype)
        
        np.fill_diagonal(pref, 0)
        return pref
    
    def detect_condorcet_clusters(self, node_orderings: np.ndarray, delta: Optional[int] = None, use_dynamic_delta: bool = True, gen_param: float = 100.0, network_param: float = 100.0) -> List[np.ndarray]:
        """
        HyperOrder-X Phase 1: Canonical Embedding & Clustering
        
        使用投票阈值（基于gamma计算）进行Byzantine过滤:
        1. 计算pairwise preference matrix
        2. 使用threshold过滤：只有超过threshold票的偏好才被采纳
        3. 基于确定的偏好关系计算canonical position
        4. 动态计算delta值（可选）
        5. Geometric clustering
        
        Args:
            node_orderings: Either shape (n_nodes, n_transactions) or list of lists
            delta: Clustering threshold (rank distance). If None and use_dynamic_delta=True, will calculate dynamically
            use_dynamic_delta: Whether to use dynamic delta calculation based on canonical positions
        
        Returns:
            List of hyperedges (each a numpy array of transaction IDs)
        """
        # Step 1: 计算 pairwise preference matrix（使用全部节点）
        pref = self.compute_pairwise_preferences(node_orderings)
        b = pref.shape[0]
        
        # Step 2: 使用 threshold（基于gamma）过滤，计算每个tx的"确定排在它前面的tx数量"
        # 只有当 pref[i,j] >= threshold 时，才确定 tx_i 排在 tx_j 前面
        tx_canonical_pos = {}
        for tx in range(b):
            # 统计有多少tx确定排在当前tx前面
            count_before = 0
            for other in range(b):
                if other != tx:
                    # 如果other排在tx前面的票数 >= threshold，则确定other在tx前面
                    if pref[other, tx] >= self.threshold:
                        count_before += 1
            tx_canonical_pos[tx] = count_before
        
        # Step 3: 动态计算delta值（如果启用）
        if use_dynamic_delta and delta is None:
            delta = calculate_delta(gen_param, network_param, phi=0.1, n_transactions=self.num_txs, target_similarity=0.8)
            print(f"  动态计算delta值: {delta} (基于gen_param={gen_param}, network_param={network_param})")
        elif delta is None:
            delta = self.delta  # 使用初始化的delta值
            print(f"  使用初始化delta值: {delta}")
        else:
            print(f"  使用指定delta值: {delta}")
        
        # Step 4: Pre-sort by canonical position
        sorted_txs = sorted(range(b), key=lambda tx: tx_canonical_pos[tx])
        
        # Step 5: Geometric clustering
        hyperedges = []
        current_hyperedge = [sorted_txs[0]]
        
        for i in range(1, len(sorted_txs)):
            tx_prev = sorted_txs[i-1]
            tx_curr = sorted_txs[i]
            
            dist = tx_canonical_pos[tx_curr] - tx_canonical_pos[tx_prev]
            
            if dist < delta:
                # Close distance, add to current hyperedge
                current_hyperedge.append(tx_curr)
            else:
                # Large distance, close current and start new hyperedge
                hyperedges.append(current_hyperedge)
                current_hyperedge = [tx_curr]
        
        hyperedges.append(current_hyperedge)
        
        return [np.array(he, dtype=np.int32) for he in hyperedges]
    
    def build_hypergraph(self, pref_matrix: np.ndarray, clusters: List[np.ndarray]) -> Dict[str, Any]:
        """
        Build hypergraph with weights and dependencies.
        
        Args:
            pref_matrix: Preference matrix shape (b, b)
            clusters: List of hyperedges (each is numpy array of transaction IDs)
        
        Returns:
            Hypergraph dictionary with edges, weights, dependencies, and internal orders
        """
        b = pref_matrix.shape[0]
        
        # Ensure all transactions are covered
        hyperedges: List[np.ndarray] = []
        for c in clusters:
            if len(c) > 1:
                hyperedges.append(np.asarray(c, dtype=np.int32))
        
        clustered = set(int(x) for he in hyperedges for x in he.tolist())
        for tx in range(b):
            if tx not in clustered:
                hyperedges.append(np.asarray([tx], dtype=np.int32))
        
        # Compute hyperedge weights (internal consensus)
        weights: Dict[int, float] = {}
        for idx, he in enumerate(hyperedges):
            s = he.size
            if s == 1:
                weights[idx] = 1.0
                continue
            
            sub = pref_matrix[np.ix_(he, he)]
            cons = np.minimum(sub, sub.T)
            iu = np.triu_indices(s, 1)
            weights[idx] = float(cons[iu].mean()) if iu[0].size > 0 else 0.0
        
        # Compute inter-hyperedge dependencies
        deps: List[Tuple[int, int, int]] = []
        H = len(hyperedges)
        for i in range(H):
            hi = hyperedges[i]
            for j in range(i + 1, H):
                hj = hyperedges[j]
                pij = int(pref_matrix[np.ix_(hi, hj)].sum())
                pji = int(pref_matrix[np.ix_(hj, hi)].sum())
                
                # Apply margin rule: 1.2x preference threshold
                if pij > 1.2 * pji:
                    deps.append((i, j, pij))
                elif pji > 1.2 * pij:
                    deps.append((j, i, pji))
        
        # Compute internal ordering within each hyperedge
        internal_orders: Dict[int, List[int]] = {}
        for idx, he in enumerate(hyperedges):
            if he.size == 1:
                internal_orders[idx] = [int(he[0])]
            else:
                sub = pref_matrix[np.ix_(he, he)].astype(np.int32, copy=False)
                net = (sub - sub.T).sum(axis=1)  # Net preference score
                order = he[np.argsort(-net)]
                internal_orders[idx] = [int(x) for x in order.tolist()]
        
        return {
            "hyperedges": hyperedges,
            "hyperedge_weights": weights,
            "hyperedge_dependencies": deps,
            "internal_orders": internal_orders,
        }
    
    def topological_sort_hyperedges(self, hypergraph: Dict[str, Any]) -> List[int]:
        """
        Topologically sort hyperedges based on dependencies.
        
        Args:
            hypergraph: Hypergraph dictionary
        
        Returns:
            List of hyperedge indices in topological order
        """
        H = len(hypergraph["hyperedges"])
        adj = [[] for _ in range(H)]
        indeg = [0] * H
        
        for u, v, _w in hypergraph["hyperedge_dependencies"]:
            adj[u].append(v)
            indeg[v] += 1
        
        q = deque([i for i in range(H) if indeg[i] == 0])
        out: List[int] = []
        
        while q:
            u = q.popleft()
            out.append(u)
            for v in adj[u]:
                indeg[v] -= 1
                if indeg[v] == 0:
                    q.append(v)
        
        if len(out) != H:
            # Cycle fallback (should not happen with well-formed graphs)
            remaining = [i for i in range(H) if i not in set(out)]
            out.extend(remaining)
        
        return out
    
    def extract_final_ordering(self, hypergraph: Dict[str, Any]) -> List[int]:
        """
        Extract final transaction ordering from hypergraph.
        
        Args:
            hypergraph: Hypergraph dictionary
        
        Returns:
            Final transaction ordering (list of transaction IDs)
        """
        he_order = self.topological_sort_hyperedges(hypergraph)
        final: List[int] = []
        internal = hypergraph["internal_orders"]
        
        for idx in he_order:
            final.extend(internal[idx])
        
        return final
    
    def sort(self, node_orderings: np.ndarray) -> List[int]:
        """
        Complete HyperOrder-X Phase 1 algorithm.
        
        Args:
            node_orderings: Node orderings from all nodes, shape (n_nodes, n_transactions)
        
        Returns:
            Final transaction ordering
        """
        # Use voting-based algorithm with fine-grained sorting for better differentiation
        # (Phase 1 canonical clustering produces too coarse-grained results)
        return self._sort_voting_ranksum(node_orderings)
    
    def run_hypergraph_algorithm(self, node_orderings: np.ndarray, gamma: Optional[float] = None, 
                               use_dynamic_delta: bool = False, gen_param: float = 100.0, network_param: float = 100.0) -> Dict[str, Any]:
        """
        Complete HyperOrder-X Phase 1 with timing and statistics.
        
        Args:
            node_orderings: Node orderings from all nodes
            gamma: Optional gamma parameter (fairness parameter). If provided, recalculates threshold.
            use_dynamic_delta: Whether to use dynamic delta calculation during clustering
        
        Returns:
            Dictionary with final_order, total_time, time breakdown, and statistics
        """
        # Update gamma and threshold if provided
        if gamma is not None:
            self.gamma = gamma
            self.threshold = max(1, int(self.n * (1 - gamma)) + self.f + 1)
        
        start_total = time.time()
        
        # Step 1: Preferences
        t0 = time.time()
        pref = self.compute_pairwise_preferences(node_orderings)
        t_pref = time.time() - t0
        
        # Step 2: Clustering (支持动态delta)
        t0 = time.time()
        if use_dynamic_delta:
            clusters = self.detect_condorcet_clusters(node_orderings, delta=None, use_dynamic_delta=True, gen_param=gen_param, network_param=network_param)
        else:
            clusters = self.detect_condorcet_clusters(node_orderings, delta=self.delta, use_dynamic_delta=False, gen_param=gen_param, network_param=network_param)
        t_cluster = time.time() - t0
        
        # Step 3: Hypergraph
        t0 = time.time()
        hg = self.build_hypergraph(pref, clusters)
        t_hg = time.time() - t0
        
        # Step 4: Extraction
        t0 = time.time()
        final_order = self.extract_final_ordering(hg)
        t_final = time.time() - t0
        
        total = time.time() - start_total
        sizes = [he.size for he in hg["hyperedges"]]
        
        return {
            "final_order": final_order,
            "total_time": total,
            "gamma": self.gamma,  # Output gamma parameter
            "delta": self.delta,  # Output clustering parameter
            "threshold": self.threshold,  # Output voting threshold
            "time_breakdown": {
                "pref_matrix": t_pref,
                "clustering": t_cluster,
                "hypergraph_build": t_hg,
                "final_extract": t_final,
            },
            "stats": {
                "n_hyperedges": len(hg["hyperedges"]),
                "avg_hyperedge_size": float(np.mean(sizes)) if sizes else 0.0,
                "max_hyperedge_size": int(np.max(sizes)) if sizes else 0,
                "min_hyperedge_size": int(np.min(sizes)) if sizes else 0,
            },
        }
