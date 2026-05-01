#ifndef _FLASHORDER_H
#define _FLASHORDER_H

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <numeric>
#include <queue>
#include <unordered_map>
#include <vector>

#include "hotstuff/entity.h"
#include "hotstuff/type.h"
#include "hotstuff/util.h"

namespace FlashOrder {

/**
 * FlashOrder (HyperOrder-X) - High Performance Edition
 *
 * 1. Uses a 1D flat vector strictly sized to n_txns * n_txns for L1/L2 cache locality.
 * 2. Bypasses redundant sorting if timestamps are already sorted.
 * 3. Exact threshold logic without loss of precision.
 */
template <int max_number_cmds> class HyperGraph {
private:
  std::vector<uint16_t> pref;
  int canonical_pos[max_number_cmds];

  struct HyperEdge {
    std::vector<int> members;
    std::vector<int> internal_order;
  };
  std::vector<HyperEdge> hyperedges;

  std::vector<std::vector<int>> he_adj;
  std::vector<int> he_indeg;

  std::unordered_map<salticidae::uint256_t, int> cmd_to_id;
  std::vector<salticidae::uint256_t> id_to_cmd;
  int n_txns;

  int threshold;
  double gamma, k, margin;
  int n_nodes, n_f;

    void compute_preferences(std::vector<hotstuff::OrderedList> &orderedlists) {
      int n_replicas = (int)orderedlists.size();
      HOTSTUFF_LOG_INFO("[[HyperGraph]] n_replicas = %d", n_replicas);
      
      for (int r = 0; r < n_replicas; r++) {
        const auto &ts = orderedlists[r].timestamps;
        if (ts.size() >= 2 && !std::is_sorted(ts.begin(), ts.end()))
          orderedlists[r].sort_cmds();
      }

      cmd_to_id.clear();
      id_to_cmd.clear();
      n_txns = 0;
      for (int r = 0; r < n_replicas; r++) {
        for (const auto &cmd : orderedlists[r].cmds) {
          if (cmd_to_id.find(cmd) == cmd_to_id.end()) {
            if (n_txns >= max_number_cmds)
              break;
            cmd_to_id[cmd] = n_txns;
            id_to_cmd.push_back(cmd);
            n_txns++;
          }
        }
      }

      HOTSTUFF_LOG_INFO("[[HyperGraph]] n_txns = %d", n_txns);
      if (n_txns == 0)
        return;

      std::vector<std::vector<int>> replica_mapped_ids(n_replicas);
      for (int r = 0; r < n_replicas; r++) {
        int n_cmds = (int)orderedlists[r].cmds.size();
        replica_mapped_ids[r].reserve(n_cmds);
        for (int i = 0; i < n_cmds; i++) {
          auto it = cmd_to_id.find(orderedlists[r].cmds[i]);
          if (it != cmd_to_id.end())
            replica_mapped_ids[r].push_back(it->second);
        }
      }

      pref.assign(n_txns * n_txns, 0);

      for (int r = 0; r < n_replicas; r++) {
        const auto &mapped_ids = replica_mapped_ids[r];
        int n_cmds = (int)mapped_ids.size();
        for (int i = 0; i < n_cmds; i++) {
          int id_i = mapped_ids[i];
          int row_id = id_i * n_txns;
          for (int j = i + 1; j < n_cmds; j++) {
            int id_j = mapped_ids[j];
            pref[row_id + id_j]++;
          }
        }
      }
      HOTSTUFF_LOG_INFO("[[HyperGraph]] compute_preferences DONE");
    }

    void compute_canonical_positions() {
      std::memset(canonical_pos, 0, sizeof(canonical_pos));
      for (int other = 0; other < n_txns; other++) {
        int row_offset = other * n_txns;
        for (int tx = 0; tx < n_txns; tx++) {
          if (other != tx && pref[row_offset + tx] >= threshold) {
            canonical_pos[tx]++;
          }
        }
      }
      HOTSTUFF_LOG_INFO("[[HyperGraph]] compute_canonical_positions DONE");
    }

    void detect_clusters_refined() {
      hyperedges.clear();
      if (n_txns == 0)
        return;
      std::vector<int> sid(n_txns);
      std::iota(sid.begin(), sid.end(), 0);
      std::sort(sid.begin(), sid.end(), [this](int a, int b) {
        return canonical_pos[a] < canonical_pos[b];
      });

      int delta = 5;
      if (n_txns >= 2) {
        double avg_gap =
            (double)(canonical_pos[sid[n_txns - 1]] - canonical_pos[sid[0]]) /
            (n_txns - 1);
        delta = (int)std::max(1.0, std::round(avg_gap * k) + (n_f * 5 / n_nodes));
      }

      HyperEdge curr;
      curr.members.push_back(sid[0]);
      for (int i = 1; i < n_txns; i++) {
        if (canonical_pos[sid[i]] - canonical_pos[sid[i - 1]] < delta) {
          curr.members.push_back(sid[i]);
        } else {
          hyperedges.push_back(curr);
          curr = HyperEdge();
          curr.members.push_back(sid[i]);
        }
      }
      hyperedges.push_back(curr);
      HOTSTUFF_LOG_INFO("[[HyperGraph]] detect_clusters_refined DONE, clusters=%lu", hyperedges.size());
    }

    void build_hypergraph() {
      int H = (int)hyperedges.size();
      if (H == 0)
        return;
      he_adj.assign(H, std::vector<int>());
      he_indeg.assign(H, 0);

      for (auto &he : hyperedges) {
        if (he.members.size() <= 1) {
          if (he.members.size() == 1)
            he.internal_order = he.members;
          continue;
        }
        std::vector<std::pair<long long, int>> scores;
        for (int m : he.members) {
          long long net = 0;
          int r_m = m * n_txns;
          for (int o : he.members) {
            if (m != o)
              net += (long long)pref[r_m + o] - (long long)pref[o * n_txns + m];
          }
          scores.push_back({net, m});
        }
        std::sort(scores.begin(), scores.end(),
                  [](const auto &a, const auto &b) { return a.first > b.first; });
        he.internal_order.clear();
        for (auto &p : scores)
          he.internal_order.push_back(p.second);
      }

      if (H == 1)
        return;

      for (int i = 0; i < H; i++) {
        for (int j = i + 1; j < H; j++) {
          long long s_ij = 0, s_ji = 0;
          for (int a : hyperedges[i].members) {
            int off_a = a * n_txns;
            for (int b : hyperedges[j].members) {
              s_ij += pref[off_a + b];
              s_ji += pref[b * n_txns + a];
            }
          }
          if ((double)s_ij > margin * (double)s_ji) {
            he_adj[i].push_back(j);
            he_indeg[j]++;
          } else if ((double)s_ji > margin * (double)s_ij) {
            he_adj[j].push_back(i);
            he_indeg[i]++;
          }
        }
      }
      HOTSTUFF_LOG_INFO("[[HyperGraph]] build_hypergraph DONE");
    }

    std::vector<int> topological_sort() {
      int H = (int)hyperedges.size();
      std::vector<int> order;
      if (H == 0)
        return order;

      std::vector<int> d = he_indeg;
      std::queue<int> q;
      for (int i = 0; i < H; i++)
        if (H > 0 && d[i] == 0)
          q.push(i);

      while (!q.empty()) {
        int u = q.front();
        q.pop();
        order.push_back(u);
        for (int v : he_adj[u]) {
          if (--d[v] == 0)
            q.push(v);
        }
      }

      if ((int)order.size() != H) {
        std::vector<bool> vis(H, false);
        for (int i : order)
          vis[i] = true;
        for (int i = 0; i < H; i++)
          if (!vis[i])
            order.push_back(i);
      }
      HOTSTUFF_LOG_INFO("[[HyperGraph]] topological_sort DONE");
      return order;
    }

public:
  HyperGraph() : margin(1.2), k(1.5), n_txns(0) {}

  std::vector<salticidae::uint256_t>
  finalize(std::vector<hotstuff::OrderedList> &orderedlists, int nfaulty,
           int nnodes, double gam = 1.0) {
    n_f = nfaulty;
    n_nodes = std::max(1, nnodes);
    gamma = gam;
    threshold = std::max(1, (int)(n_nodes * (1.0 - gamma)) + n_f + 1);

    compute_preferences(orderedlists);
    if (n_txns == 0)
      return {};
    if (n_txns == 1)
      return {id_to_cmd[0]};

    compute_canonical_positions();
    detect_clusters_refined();
    build_hypergraph();

    std::vector<int> order = topological_sort();
    std::vector<salticidae::uint256_t> result;
    result.reserve(n_txns);
    for (int idx : order) {
      for (int tid : hyperedges[idx].internal_order) {
        result.push_back(id_to_cmd[tid]);
      }
    }
    return result;
  }
};

} // namespace FlashOrder

#endif