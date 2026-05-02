/**
 * Evil Client for injecting Condorcet cycles
 */

#include <cassert>
#include <random>
#include <memory>
#include <signal.h>
#include <sys/time.h>
#include <iostream>

#include "salticidae/type.h"
#include "salticidae/netaddr.h"
#include "salticidae/network.h"
#include "salticidae/util.h"

#include "hotstuff/util.h"
#include "hotstuff/type.h"
#include "hotstuff/client.h"
#include "small_bank.h"

using salticidae::Config;

using hotstuff::ReplicaID;
using hotstuff::NetAddr;
using hotstuff::EventContext;
using hotstuff::MsgReqCmd;
using hotstuff::MsgRespCmd;
using hotstuff::CommandDummy;
using hotstuff::HotStuffError;
using hotstuff::uint256_t;
using hotstuff::opcode_t;
using hotstuff::command_t;

EventContext ec;
size_t max_async_num;
int max_iter_num;
uint32_t cid;
uint32_t cnt = 0;
uint32_t nfaulty;

struct Request {
    command_t cmd;
    size_t confirmed;
    salticidae::ElapsedTime et;
    Request(const command_t &cmd): cmd(cmd), confirmed(0) { et.start(); }
};

using Net = salticidae::MsgNetwork<opcode_t>;

std::unordered_map<ReplicaID, Net::conn_t> conns;
std::unordered_map<const uint256_t, Request> waiting;
std::vector<NetAddr> replicas;
std::vector<std::pair<struct timeval, double>> elapsed;
std::unique_ptr<Net> mn;
SmallBankManager *small_bank_manager;
double time_consumed_in_cmd_generation = 0.0;

int cycles_to_inject = 0;
int current_cycle = 0;

void connect_all() {
    for (size_t i = 0; i < replicas.size(); i++)
        conns.insert(std::make_pair(i, mn->connect_sync(replicas[i])));
}

bool try_send(bool check = true) {
    if ((!check || waiting.size() < max_async_num) && current_cycle < cycles_to_inject)
    {
        // Generate 3 transactions for a cycle
        auto tx1 = small_bank_manager->get_next_transaction_serialized();
        auto cmd1 = new CommandDummy(cid, cnt++, tx1);
        MsgReqCmd msg1(*cmd1);

        auto tx2 = small_bank_manager->get_next_transaction_serialized();
        auto cmd2 = new CommandDummy(cid, cnt++, tx2);
        MsgReqCmd msg2(*cmd2);

        auto tx3 = small_bank_manager->get_next_transaction_serialized();
        auto cmd3 = new CommandDummy(cid, cnt++, tx3);
        MsgReqCmd msg3(*cmd3);

        // Send to G1 (0-6): T1 -> T2 -> T3
        for (size_t i = 0; i < 7 && i < replicas.size(); i++) {
            mn->send_msg(msg1, conns[i]);
            mn->send_msg(msg2, conns[i]);
            mn->send_msg(msg3, conns[i]);
        }

        // Send to G2 (7-13): T2 -> T3 -> T1
        for (size_t i = 7; i < 14 && i < replicas.size(); i++) {
            mn->send_msg(msg2, conns[i]);
            mn->send_msg(msg3, conns[i]);
            mn->send_msg(msg1, conns[i]);
        }

        // Send to G3 (14-20): T3 -> T1 -> T2
        for (size_t i = 14; i < 21 && i < replicas.size(); i++) {
            mn->send_msg(msg3, conns[i]);
            mn->send_msg(msg1, conns[i]);
            mn->send_msg(msg2, conns[i]);
        }

        waiting.insert(std::make_pair(cmd1->get_hash(), Request(cmd1)));
        waiting.insert(std::make_pair(cmd2->get_hash(), Request(cmd2)));
        waiting.insert(std::make_pair(cmd3->get_hash(), Request(cmd3)));
        
        current_cycle++;
        if (current_cycle % 10 == 0) {
            HOTSTUFF_LOG_INFO("Injected %d cycles...", current_cycle);
        }
        return true;
    }
    return false;
}

void client_resp_cmd_handler(MsgRespCmd &&msg, const Net::conn_t &) {
    auto &fin = msg.fin;
    const uint256_t &cmd_hash = fin.cmd_hash;
    auto it = waiting.find(cmd_hash);
    if (it == waiting.end()) return;
    auto &et = it->second.et;
    et.stop();
    if (++it->second.confirmed <= nfaulty) return; // wait for f + 1 ack
    waiting.erase(it);
    
    if (waiting.empty() && current_cycle >= cycles_to_inject) {
        HOTSTUFF_LOG_INFO("All cycles confirmed. Exiting.");
        ec.stop();
    } else {
        while (try_send());
    }
}

std::pair<std::string, std::string> split_ip_port_cport(const std::string &s) {
    auto ret = salticidae::trim_all(salticidae::split(s, ";"));
    return std::make_pair(ret[0], ret[1]);
}

int main(int argc, char **argv) {
    Config config("hotstuff.conf");

    auto opt_sb_users = Config::OptValInt::create(10);
    auto opt_sb_prob_choose_mtx = Config::OptValDouble::create(0.9);
    auto opt_sb_skew_factor = Config::OptValDouble::create(0.1);
    auto opt_fairness_parameter = Config::OptValDouble::create(1);  // Themis
    auto opt_idx = Config::OptValInt::create(0);
    auto opt_replicas = Config::OptValStrVec::create();
    auto opt_max_iter_num = Config::OptValInt::create(100);
    auto opt_max_async_num = Config::OptValInt::create(10);
    auto opt_cid = Config::OptValInt::create(-1);
    auto opt_max_cli_msg = Config::OptValInt::create(65536); // 64K by default
    auto opt_cycles = Config::OptValInt::create(100);

    auto shutdown = [&](int) { ec.stop(); };
    salticidae::SigEvent ev_sigint(ec, shutdown);
    salticidae::SigEvent ev_sigterm(ec, shutdown);
    ev_sigint.add(SIGINT);
    ev_sigterm.add(SIGTERM);

    mn = std::make_unique<Net>(ec, Net::Config().max_msg_size(opt_max_cli_msg->get()));
    mn->reg_handler(client_resp_cmd_handler);
    mn->start();

    config.add_opt("sb-users", opt_sb_users, Config::SET_VAL);
    config.add_opt("sb-prob-choose_mtx", opt_sb_prob_choose_mtx, Config::SET_VAL);
    config.add_opt("sb-skew-factor", opt_sb_skew_factor, Config::SET_VAL);
    config.add_opt("fairness-parameter", opt_fairness_parameter, Config::SET_VAL);  // Themis
    config.add_opt("idx", opt_idx, Config::SET_VAL);
    config.add_opt("cid", opt_cid, Config::SET_VAL);
    config.add_opt("replica", opt_replicas, Config::APPEND);
    config.add_opt("iter", opt_max_iter_num, Config::SET_VAL);
    config.add_opt("max-async", opt_max_async_num, Config::SET_VAL);
    config.add_opt("max-cli-msg", opt_max_cli_msg, Config::SET_VAL, 'S', "the maximum client message size");
    config.add_opt("cycles", opt_cycles, Config::SET_VAL, 'C', "number of cycles to inject");
    config.parse(argc, argv);
    
    auto idx = opt_idx->get();
    max_iter_num = opt_max_iter_num->get();
    max_async_num = opt_max_async_num->get();
    cycles_to_inject = opt_cycles->get();
    
    std::vector<std::string> raw;
    for (const auto &s: opt_replicas->get())
    {
        auto res = salticidae::trim_all(salticidae::split(s, ","));
        if (res.size() < 1)
            throw HotStuffError("format error");
        raw.push_back(res[0]);
    }

    if (!(0 <= idx && (size_t)idx < raw.size() && raw.size() > 0))
        throw std::invalid_argument("out of range");
    cid = opt_cid->get() != -1 ? opt_cid->get() : idx;
    for (const auto &p: raw)
    {
        auto _p = split_ip_port_cport(p);
        size_t _;
        replicas.push_back(NetAddr(NetAddr(_p.first).ip, htons(stoi(_p.second, &_))));
    }

    double fairness_parameter = opt_fairness_parameter->get();
    nfaulty = (replicas.size() * ((2*fairness_parameter) -1))/4;
    HOTSTUFF_LOG_INFO("nfaulty = %zu, injecting %d cycles", nfaulty, cycles_to_inject);

    small_bank_manager = new SmallBankManager(opt_sb_users->get(), opt_sb_prob_choose_mtx->get(), opt_sb_skew_factor->get());

    connect_all();
    while (try_send());
    ec.dispatch();

    return 0;
}
