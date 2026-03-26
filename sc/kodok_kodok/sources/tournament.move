/// Weekly tournament system for Kodok-Kodok.
///
/// Flow:
///   Admin calls `create_tournament` → shared Tournament object on-chain.
///   Players call `join_tournament` (fixed 10 HKT entry fee) → added to prize pool.
///   Each resolved round calls `record_round_result` (package-visible) to track P&L.
///   Anyone calls `finalize_tournament` after `end_time` → prizes distributed.
///
/// P&L tracking: signed values are split into `profit: u64` + `loss: u64` because
/// this version of Move does not support signed integer types (i8/i16/i32/i64/…).
/// Net PnL = profit − loss; computed off-chain by the frontend.
///
/// Prize distribution (by net P&L, descending):
///   3+ players: 1st 50% | 2nd 30% | 3rd 20%
///   2 players:  1st 60% | 2nd 40%
///   1 player:   1st 100%
///   0 players:  no distribution; admin may call `withdraw_remaining`.
///
/// Tiebreaker: earlier join order wins.
module kodok_kodok::tournament;

use hackathon::hackathon::HACKATHON;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::table::{Self, Table};

// ============================================================================
// Constants
// ============================================================================

/// 7 × 24 × 60 × 60 × 1000 ms
const MS_PER_WEEK: u64 = 604_800_000;

/// Fixed entry fee: 10 HACKATHON (10_000_000_000 MIST)
const ENTRY_FEE: u64 = 10_000_000_000;

// Error codes — always module-private in Move (no `public` on const)
const E_ALREADY_JOINED:       u64 = 0;
const E_INVALID_ENTRY_FEE:    u64 = 1;
const E_TOURNAMENT_ENDED:     u64 = 2;
const E_TOURNAMENT_NOT_ENDED: u64 = 3;
const E_ALREADY_FINALIZED:    u64 = 4;
const E_PLAYER_NOT_JOINED:    u64 = 5;

// ============================================================================
// Structs
// ============================================================================

/// Admin capability — transferred to the deployer at `init`. Never shared.
public struct TournamentAdmin has key {
    id: UID,
}

/// Global tournament state — shared object visible to all players.
/// `player_addresses` mirrors Table keys to allow iteration
/// (sui::table has no built-in iterator).
public struct Tournament has key {
    id: UID,
    week: u64,
    prize_pool: Balance<HACKATHON>,
    start_time: u64,
    end_time: u64,
    players: Table<address, PlayerStats>,
    player_addresses: vector<address>,
    finalized: bool,
}

/// Per-player stats. P&L is stored as two unsigned fields because Move lacks
/// signed integer types in this build.
///   net_pnl = profit − loss   (compute off-chain)
public struct PlayerStats has store {
    profit: u64,           // cumulative HKT won
    loss: u64,             // cumulative HKT lost
    rounds_played: u64,
    joined_at: u64,        // epoch_timestamp_ms at join time (tiebreaker)
}

/// One entry returned by `get_leaderboard`.
public struct LeaderboardEntry has copy, drop, store {
    rank: u64,
    player: address,
    profit: u64,
    loss: u64,
    rounds_played: u64,
}

// ============================================================================
// Events
// ============================================================================

public struct PlayerJoined has copy, drop {
    tournament_id: ID,
    player: address,
    prize_pool: u64,
}

public struct TournamentFinalized has copy, drop {
    week: u64,
    winners: vector<address>,
    prizes: vector<u64>,
}

// ============================================================================
// Module Initializer
// ============================================================================

fun init(ctx: &mut TxContext) {
    transfer::transfer(
        TournamentAdmin { id: object::new(ctx) },
        ctx.sender(),
    );
}

// ============================================================================
// Admin Functions
// ============================================================================

/// Create and share a new tournament.
///
/// `duration_ms` — how long the tournament runs (e.g. MS_PER_WEEK = 604_800_000).
/// Entry fee is fixed at ENTRY_FEE (10 HKT).
/// Start time is derived from `ctx.epoch_timestamp_ms()`.
public fun create_tournament(
    _admin: &TournamentAdmin,
    duration_ms: u64,
    ctx: &mut TxContext,
) {
    let now  = ctx.epoch_timestamp_ms();
    let week = now / MS_PER_WEEK;

    transfer::share_object(Tournament {
        id: object::new(ctx),
        week,
        prize_pool: balance::zero(),
        start_time: now,
        end_time: now + duration_ms,
        players: table::new(ctx),
        player_addresses: vector[],
        finalized: false,
    });
}

/// Sweep any dust balance remaining after finalization back to the admin wallet.
#[allow(lint(self_transfer))]
public fun withdraw_remaining(
    _admin: &TournamentAdmin,
    tournament: &mut Tournament,
    ctx: &mut TxContext,
) {
    assert!(tournament.finalized, E_TOURNAMENT_NOT_ENDED);
    let remaining = tournament.prize_pool.value();
    if (remaining > 0) {
        let dust = tournament.prize_pool.split(remaining);
        transfer::public_transfer(coin::from_balance(dust, ctx), ctx.sender());
    };
}

// ============================================================================
// Player Functions
// ============================================================================

/// Pay the fixed 10 HKT entry fee to join.
/// Each address may join once before `end_time`.
/// Entry fee must equal ENTRY_FEE (10_000_000_000 MIST) exactly.
public fun join_tournament(
    tournament: &mut Tournament,
    entry_fee: Coin<HACKATHON>,
    ctx: &mut TxContext,
) {
    let player = ctx.sender();
    let now    = ctx.epoch_timestamp_ms();

    assert!(now < tournament.end_time, E_TOURNAMENT_ENDED);
    assert!(!tournament.players.contains(player), E_ALREADY_JOINED);
    assert!(entry_fee.value() == ENTRY_FEE, E_INVALID_ENTRY_FEE);

    tournament.prize_pool.join(entry_fee.into_balance());
    tournament.players.add(player, PlayerStats {
        profit: 0,
        loss: 0,
        rounds_played: 0,
        joined_at: now,
    });
    tournament.player_addresses.push_back(player);

    event::emit(PlayerJoined {
        tournament_id: object::id(tournament),
        player,
        prize_pool: tournament.prize_pool.value(),
    });
}

// ============================================================================
// Package-internal — called by kodok_kodok::kodok_kodok::resolve_round
// ============================================================================

/// Update a tournament participant's cumulative P&L after a round completes.
///
/// `profit` — amount won this round (0 if player lost or broke even).
/// `loss`   — amount lost this round (0 if player won or broke even).
///
/// Visibility: `public(package)` — only modules in the `kodok_kodok` package
/// may call this.
public(package) fun record_round_result(
    tournament: &mut Tournament,
    player: address,
    profit: u64,
    loss: u64,
) {
    if (tournament.finalized) return;
    if (!tournament.players.contains(player)) return;

    let stats = tournament.players.borrow_mut(player);
    stats.profit        = stats.profit        + profit;
    stats.loss          = stats.loss          + loss;
    stats.rounds_played = stats.rounds_played + 1;
}

// ============================================================================
// Finalize
// ============================================================================

/// Distribute the prize pool to top-3 players (by net P&L = profit − loss).
/// Can be called by anyone once `ctx.epoch_timestamp_ms() >= end_time`.
public fun finalize_tournament(
    tournament: &mut Tournament,
    ctx: &mut TxContext,
) {
    assert!(!tournament.finalized, E_ALREADY_FINALIZED);
    assert!(ctx.epoch_timestamp_ms() >= tournament.end_time, E_TOURNAMENT_NOT_ENDED);

    tournament.finalized = true;

    let sorted = sort_by_pnl_desc(&tournament.player_addresses, &tournament.players);
    let n      = sorted.length();
    let total  = tournament.prize_pool.value();

    let mut winners: vector<address> = vector[];
    let mut prizes:  vector<u64>     = vector[];

    if (n == 0 || total == 0) {
        // Nothing to distribute; admin may call withdraw_remaining later.
    } else if (n == 1) {
        let all = tournament.prize_pool.split(total);
        transfer::public_transfer(coin::from_balance(all, ctx), sorted[0]);
        winners.push_back(sorted[0]);
        prizes.push_back(total);
    } else if (n == 2) {
        let p1 = total * 60 / 100;
        let p2 = total - p1;
        pay_prize(&mut tournament.prize_pool, sorted[0], p1, ctx);
        pay_prize(&mut tournament.prize_pool, sorted[1], p2, ctx);
        winners.push_back(sorted[0]); prizes.push_back(p1);
        winners.push_back(sorted[1]); prizes.push_back(p2);
    } else {
        // 3+ players: 50 / 30 / remainder-to-3rd
        let p1 = total * 50 / 100;
        let p2 = total * 30 / 100;
        let p3 = total - p1 - p2;
        pay_prize(&mut tournament.prize_pool, sorted[0], p1, ctx);
        pay_prize(&mut tournament.prize_pool, sorted[1], p2, ctx);
        pay_prize(&mut tournament.prize_pool, sorted[2], p3, ctx);
        winners.push_back(sorted[0]); prizes.push_back(p1);
        winners.push_back(sorted[1]); prizes.push_back(p2);
        winners.push_back(sorted[2]); prizes.push_back(p3);
    };

    event::emit(TournamentFinalized { week: tournament.week, winners, prizes });
}

// ============================================================================
// View Functions
// ============================================================================

/// Return top-10 players sorted by net P&L (profit − loss) descending.
public fun get_leaderboard(tournament: &Tournament): vector<LeaderboardEntry> {
    let sorted = sort_by_pnl_desc(&tournament.player_addresses, &tournament.players);
    let n      = sorted.length();
    let limit  = if (n > 10) { 10 } else { n };

    let mut result: vector<LeaderboardEntry> = vector[];
    let mut i = 0u64;
    while (i < limit) {
        let addr  = sorted[i];
        let stats = tournament.players.borrow(addr);
        result.push_back(LeaderboardEntry {
            rank:          i + 1,
            player:        addr,
            profit:        stats.profit,
            loss:          stats.loss,
            rounds_played: stats.rounds_played,
        });
        i = i + 1;
    };
    result
}

public fun prize_pool(t: &Tournament): u64    { t.prize_pool.value() }
public fun is_finalized(t: &Tournament): bool { t.finalized }
public fun player_count(t: &Tournament): u64  { t.player_addresses.length() }
public fun week(t: &Tournament): u64          { t.week }
public fun start_time(t: &Tournament): u64    { t.start_time }
public fun end_time(t: &Tournament): u64      { t.end_time }

/// Returns (profit, loss, rounds_played). Aborts if player has not joined.
public fun player_stats(t: &Tournament, player: address): (u64, u64, u64) {
    assert!(t.players.contains(player), E_PLAYER_NOT_JOINED);
    let s = t.players.borrow(player);
    (s.profit, s.loss, s.rounds_played)
}

public fun has_player(t: &Tournament, player: address): bool {
    t.players.contains(player)
}

/// LeaderboardEntry field getters — needed because struct fields are
/// module-private in Move 2024 and the test module is a separate module.
public fun entry_rank(e: &LeaderboardEntry): u64          { e.rank }
public fun entry_player(e: &LeaderboardEntry): address    { e.player }
public fun entry_profit(e: &LeaderboardEntry): u64        { e.profit }
public fun entry_loss(e: &LeaderboardEntry): u64          { e.loss }
public fun entry_rounds(e: &LeaderboardEntry): u64        { e.rounds_played }

// ============================================================================
// Private Helpers
// ============================================================================

/// Selection sort: returns all addresses in descending net-P&L order.
/// Comparison avoids signed arithmetic:
///   profit_a − loss_a > profit_b − loss_b
///   ↔  profit_a + loss_b > profit_b + loss_a
/// Tiebreaker: earlier join order (lower joined_at) wins.
/// O(n²) — acceptable at hackathon scale; gas limits are the real ceiling.
fun sort_by_pnl_desc(
    addresses: &vector<address>,
    players: &Table<address, PlayerStats>,
): vector<address> {
    let n = addresses.length();
    if (n == 0) { return vector[] };

    let mut used: vector<bool> = vector[];
    let mut i = 0u64;
    while (i < n) { used.push_back(false); i = i + 1 };

    let mut result: vector<address> = vector[];

    let mut k = 0u64;
    while (k < n) {
        let mut best_idx = 0u64;
        let mut found = false;

        let mut j = 0u64;
        while (j < n) {
            if (!used[j]) {
                if (!found) {
                    best_idx = j;
                    found    = true;
                } else if (is_better(
                    players.borrow(addresses[j]),
                    players.borrow(addresses[best_idx]),
                )) {
                    best_idx = j;
                };
            };
            j = j + 1;
        };

        if (found) {
            result.push_back(addresses[best_idx]);
            let flag = used.borrow_mut(best_idx);
            *flag = true;
        };
        k = k + 1;
    };
    result
}

/// True if player `a` has strictly better net P&L than player `b`.
fun is_better(a: &PlayerStats, b: &PlayerStats): bool {
    // profit_a + loss_b > profit_b + loss_a  ↔  net_a > net_b
    a.profit + b.loss > b.profit + a.loss
}

/// Split `amount` from `pool` and send it to `recipient`.
fun pay_prize(
    pool: &mut Balance<HACKATHON>,
    recipient: address,
    amount: u64,
    ctx: &mut TxContext,
) {
    let prize = pool.split(amount);
    transfer::public_transfer(coin::from_balance(prize, ctx), recipient);
}

// ============================================================================
// Test Helpers
// ============================================================================

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

/// Override end_time so tests can trigger finalization without advancing the clock.
/// Set to 0 so that epoch_timestamp_ms (= 0 in test scenarios) satisfies
/// `timestamp_ms >= end_time`.
#[test_only]
public fun set_end_time_for_testing(t: &mut Tournament, end_time: u64) {
    t.end_time = end_time;
}

/// Directly set a joined player's profit/loss for leaderboard scenario tests.
#[test_only]
public fun set_player_stats_for_testing(
    t: &mut Tournament,
    player: address,
    profit: u64,
    loss: u64,
) {
    assert!(t.players.contains(player), E_PLAYER_NOT_JOINED);
    let s = t.players.borrow_mut(player);
    s.profit = profit;
    s.loss   = loss;
}
