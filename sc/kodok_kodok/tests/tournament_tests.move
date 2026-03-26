/// Unit tests for kodok_kodok::tournament.
///
/// P&L is stored as (profit: u64, loss: u64); net = profit − loss.
/// Entry fee is fixed at 10 HKT (10_000_000_000 MIST).
///
/// Time is provided by ctx.epoch_timestamp_ms() which equals 0 in test
/// scenarios. To simulate "tournament expired", tests call
/// set_end_time_for_testing(t, 0) so that 0 >= 0 is satisfied.
///
/// Prize split reference (10 HKT entry fee):
///   1 player  → 10 HKT (100%)
///   2 players → 12 HKT (60%) + 8 HKT (40%)               total 20 HKT
///   3 players → 15 HKT (50%) + 9 HKT (30%) + 6 HKT (20%) total 30 HKT
#[test_only]
#[allow(unused_mut_ref)]
module kodok_kodok::tournament_tests;

use sui::coin::{Self, Coin};
use sui::test_scenario as ts;
use hackathon::hackathon::HACKATHON;
use kodok_kodok::tournament::{
    Self,
    TournamentAdmin,
    Tournament,
};

// ============================================================================
// Test constants
// ============================================================================

const ADMIN:   address = @0xAD;
const PLAYER1: address = @0xA1;
const PLAYER2: address = @0xA2;
const PLAYER3: address = @0xA3;

const MIST:      u64 = 1_000_000_000;   // 1 HKT
const ENTRY_FEE: u64 = 10_000_000_000;  // 10 HKT — must match tournament.move
const WEEK_MS:   u64 = 604_800_000;     // 7 days in ms

// Error codes mirrored here so #[expected_failure] can reference them as literals.
// Keep in sync with tournament.move constants.
const E_ALREADY_JOINED:       u64 = 0;
const E_INVALID_ENTRY_FEE:    u64 = 1;
const E_TOURNAMENT_ENDED:     u64 = 2;
const E_TOURNAMENT_NOT_ENDED: u64 = 3;
const E_ALREADY_FINALIZED:    u64 = 4;

// ============================================================================
// Setup helpers
// ============================================================================

/// Deploy tournament module and create one tournament (duration = 1 week).
/// epoch_timestamp_ms = 0 in test scenarios → start_time = 0, end_time = WEEK_MS.
fun setup(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, ADMIN);
    tournament::init_for_testing(ts::ctx(scenario));

    ts::next_tx(scenario, ADMIN);
    {
        let admin = ts::take_from_sender<TournamentAdmin>(scenario);
        tournament::create_tournament(&admin, WEEK_MS, ts::ctx(scenario));
        ts::return_to_sender(scenario, admin);
    };
}

fun player_join(scenario: &mut ts::Scenario, player: address) {
    ts::next_tx(scenario, player);
    let mut t = ts::take_shared<Tournament>(scenario);
    let fee   = coin::mint_for_testing<HACKATHON>(ENTRY_FEE, ts::ctx(scenario));
    tournament::join_tournament(&mut t, fee, ts::ctx(scenario));
    ts::return_shared(t);
}

/// Set tournament end_time = 0 so epoch_timestamp_ms (= 0) satisfies
/// `timestamp_ms >= end_time`, allowing finalize / blocking new joins.
fun expire_tournament(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, ADMIN);
    let mut t = ts::take_shared<Tournament>(scenario);
    tournament::set_end_time_for_testing(&mut t, 0);
    ts::return_shared(t);
}

// ============================================================================
// init
// ============================================================================

#[test]
fun test_init_creates_admin() {
    let mut s = ts::begin(ADMIN);
    ts::next_tx(&mut s, ADMIN);
    tournament::init_for_testing(ts::ctx(&mut s));
    ts::next_tx(&mut s, ADMIN);
    assert!(ts::has_most_recent_for_sender<TournamentAdmin>(&s));
    ts::end(s);
}

// ============================================================================
// create_tournament
// ============================================================================

#[test]
fun test_create_tournament_initial_state() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);

    ts::next_tx(&mut s, ADMIN);
    {
        let t = ts::take_shared<Tournament>(&s);
        assert!(!tournament::is_finalized(&t));
        assert!(tournament::prize_pool(&t)   == 0);
        assert!(tournament::player_count(&t) == 0);
        assert!(tournament::start_time(&t)   == 0);       // epoch_timestamp_ms = 0 in tests
        assert!(tournament::end_time(&t)     == WEEK_MS);
        ts::return_shared(t);
    };
    ts::end(s);
}

// ============================================================================
// join_tournament
// ============================================================================

#[test]
fun test_join_increases_prize_pool() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);

    ts::next_tx(&mut s, ADMIN);
    {
        let t = ts::take_shared<Tournament>(&s);
        assert!(tournament::player_count(&t) == 1);
        assert!(tournament::prize_pool(&t)   == ENTRY_FEE);
        assert!(tournament::has_player(&t, PLAYER1));
        ts::return_shared(t);
    };
    ts::end(s);
}

#[test]
fun test_join_multiple_players_accumulates_pool() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);
    player_join(&mut s, PLAYER2);
    player_join(&mut s, PLAYER3);

    ts::next_tx(&mut s, ADMIN);
    {
        let t = ts::take_shared<Tournament>(&s);
        assert!(tournament::player_count(&t) == 3);
        assert!(tournament::prize_pool(&t)   == 3 * ENTRY_FEE);
        ts::return_shared(t);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = E_ALREADY_JOINED, location = kodok_kodok::tournament)]
fun test_join_twice_fails() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);

    ts::next_tx(&mut s, PLAYER1);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        let fee   = coin::mint_for_testing<HACKATHON>(ENTRY_FEE, ts::ctx(&mut s));
        tournament::join_tournament(&mut t, fee, ts::ctx(&mut s));
        ts::return_shared(t);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = E_INVALID_ENTRY_FEE, location = kodok_kodok::tournament)]
fun test_join_wrong_fee_fails() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);

    ts::next_tx(&mut s, PLAYER1);
    {
        let mut t     = ts::take_shared<Tournament>(&mut s);
        let wrong_fee = coin::mint_for_testing<HACKATHON>(MIST, ts::ctx(&mut s)); // 1 HKT ≠ 10 HKT
        tournament::join_tournament(&mut t, wrong_fee, ts::ctx(&mut s));
        ts::return_shared(t);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = E_TOURNAMENT_ENDED, location = kodok_kodok::tournament)]
fun test_join_after_end_time_fails() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    expire_tournament(&mut s); // end_time = 0; epoch_timestamp_ms (0) >= 0 → ended

    ts::next_tx(&mut s, PLAYER1);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        let fee   = coin::mint_for_testing<HACKATHON>(ENTRY_FEE, ts::ctx(&mut s));
        tournament::join_tournament(&mut t, fee, ts::ctx(&mut s));
        ts::return_shared(t);
    };
    ts::end(s);
}

// ============================================================================
// record_round_result  (profit: u64, loss: u64)
// ============================================================================

#[test]
fun test_record_win_updates_profit() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        tournament::record_round_result(&mut t, PLAYER1, 500, 0); // won 500
        let (profit, loss, rounds) = tournament::player_stats(&t, PLAYER1);
        assert!(profit == 500);
        assert!(loss   == 0);
        assert!(rounds == 1);
        ts::return_shared(t);
    };
    ts::end(s);
}

#[test]
fun test_record_loss_updates_loss() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        tournament::record_round_result(&mut t, PLAYER1, 0, 200); // lost 200
        let (profit, loss, rounds) = tournament::player_stats(&t, PLAYER1);
        assert!(profit == 0);
        assert!(loss   == 200);
        assert!(rounds == 1);
        ts::return_shared(t);
    };
    ts::end(s);
}

#[test]
fun test_record_multiple_rounds_cumulates() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        tournament::record_round_result(&mut t, PLAYER1, 300,   0); // +300
        tournament::record_round_result(&mut t, PLAYER1,   0, 100); // −100
        tournament::record_round_result(&mut t, PLAYER1, 200,   0); // +200
        let (profit, loss, rounds) = tournament::player_stats(&t, PLAYER1);
        assert!(profit == 500);  // 300 + 200
        assert!(loss   == 100);
        assert!(rounds == 3);
        ts::return_shared(t);
    };
    ts::end(s);
}

/// record_round_result silently skips non-participants — it must not abort
/// because it is called from within the game-round resolution flow.
#[test]
fun test_record_non_participant_silently_skips() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        // PLAYER1 has not joined — call must return without aborting
        tournament::record_round_result(&mut t, PLAYER1, 100, 0);
        // player was never added, so has_player is still false
        assert!(!tournament::has_player(&t, PLAYER1));
        ts::return_shared(t);
    };
    ts::end(s);
}

/// record_round_result silently skips on a finalized tournament — it must
/// not abort so it can be safely called from game-round resolution flow.
#[test]
fun test_record_after_finalize_silently_skips() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);
    expire_tournament(&mut s);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        tournament::finalize_tournament(&mut t, ts::ctx(&mut s));

        // Stats before the call
        let (profit_before, loss_before, rounds_before) = tournament::player_stats(&t, PLAYER1);

        // Call on finalized tournament — must return without aborting
        tournament::record_round_result(&mut t, PLAYER1, 100, 0);

        // Stats must be unchanged
        let (profit_after, loss_after, rounds_after) = tournament::player_stats(&t, PLAYER1);
        assert!(profit_after == profit_before);
        assert!(loss_after   == loss_before);
        assert!(rounds_after == rounds_before);

        ts::return_shared(t);
    };
    ts::end(s);
}

// ============================================================================
// finalize_tournament — prize distribution
// ============================================================================

#[test]
fun test_finalize_zero_players() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    expire_tournament(&mut s);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        tournament::finalize_tournament(&mut t, ts::ctx(&mut s));
        assert!(tournament::is_finalized(&t));
        assert!(tournament::prize_pool(&t) == 0);
        ts::return_shared(t);
    };
    ts::end(s);
}

#[test]
fun test_finalize_one_player_wins_all() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);
    expire_tournament(&mut s);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        tournament::finalize_tournament(&mut t, ts::ctx(&mut s));
        assert!(tournament::prize_pool(&t) == 0);
        ts::return_shared(t);
    };

    ts::next_tx(&mut s, PLAYER1);
    {
        let coin = ts::take_from_sender<Coin<HACKATHON>>(&s);
        assert!(coin.value() == ENTRY_FEE); // 10 HKT
        ts::return_to_sender(&mut s, coin);
    };
    ts::end(s);
}

#[test]
fun test_finalize_two_players_60_40_split() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);
    player_join(&mut s, PLAYER2);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        // PLAYER1: net +1000  |  PLAYER2: net +200
        tournament::set_player_stats_for_testing(&mut t, PLAYER1, 1000, 0);
        tournament::set_player_stats_for_testing(&mut t, PLAYER2,  200, 0);
        ts::return_shared(t);
    };
    expire_tournament(&mut s);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        tournament::finalize_tournament(&mut t, ts::ctx(&mut s));
        assert!(tournament::prize_pool(&t) == 0);
        ts::return_shared(t);
    };

    // Total = 20 HKT → 1st 12 HKT (60%), 2nd 8 HKT (40%)
    ts::next_tx(&mut s, PLAYER1);
    {
        let coin = ts::take_from_sender<Coin<HACKATHON>>(&s);
        assert!(coin.value() == 12 * MIST);
        ts::return_to_sender(&mut s, coin);
    };
    ts::next_tx(&mut s, PLAYER2);
    {
        let coin = ts::take_from_sender<Coin<HACKATHON>>(&s);
        assert!(coin.value() == 8 * MIST);
        ts::return_to_sender(&mut s, coin);
    };
    ts::end(s);
}

#[test]
fun test_finalize_three_players_50_30_20_split() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);
    player_join(&mut s, PLAYER2);
    player_join(&mut s, PLAYER3);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        // PLAYER2 wins, PLAYER3 second, PLAYER1 last
        tournament::set_player_stats_for_testing(&mut t, PLAYER1,  100, 0);
        tournament::set_player_stats_for_testing(&mut t, PLAYER2, 9000, 0);
        tournament::set_player_stats_for_testing(&mut t, PLAYER3,  500, 0);
        ts::return_shared(t);
    };
    expire_tournament(&mut s);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        tournament::finalize_tournament(&mut t, ts::ctx(&mut s));
        assert!(tournament::prize_pool(&t) == 0);
        ts::return_shared(t);
    };

    // Total = 30 HKT → 1st 15 HKT, 2nd 9 HKT, 3rd 6 HKT
    ts::next_tx(&mut s, PLAYER2);
    {
        let coin = ts::take_from_sender<Coin<HACKATHON>>(&s);
        assert!(coin.value() == 15 * MIST);
        ts::return_to_sender(&mut s, coin);
    };
    ts::next_tx(&mut s, PLAYER3);
    {
        let coin = ts::take_from_sender<Coin<HACKATHON>>(&s);
        assert!(coin.value() == 9 * MIST);
        ts::return_to_sender(&mut s, coin);
    };
    ts::next_tx(&mut s, PLAYER1);
    {
        let coin = ts::take_from_sender<Coin<HACKATHON>>(&s);
        assert!(coin.value() == 6 * MIST);
        ts::return_to_sender(&mut s, coin);
    };
    ts::end(s);
}

#[test]
fun test_finalize_all_negative_pnl_least_negative_wins() {
    // All players lose money in-game; the least-negative player wins the pool.
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);
    player_join(&mut s, PLAYER2);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        // PLAYER1: net −100  |  PLAYER2: net −999  →  PLAYER1 wins
        tournament::set_player_stats_for_testing(&mut t, PLAYER1, 0, 100);
        tournament::set_player_stats_for_testing(&mut t, PLAYER2, 0, 999);
        ts::return_shared(t);
    };
    expire_tournament(&mut s);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        tournament::finalize_tournament(&mut t, ts::ctx(&mut s));
        ts::return_shared(t);
    };

    ts::next_tx(&mut s, PLAYER1);
    {
        let coin = ts::take_from_sender<Coin<HACKATHON>>(&s);
        assert!(coin.value() == 12 * MIST); // 60% of 20 HKT
        ts::return_to_sender(&mut s, coin);
    };
    ts::end(s);
}

// ============================================================================
// finalize error cases
// ============================================================================

#[test]
#[expected_failure(abort_code = E_TOURNAMENT_NOT_ENDED, location = kodok_kodok::tournament)]
fun test_finalize_before_end_time_fails() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s); // epoch_timestamp_ms = 0, end_time = WEEK_MS → too early

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        tournament::finalize_tournament(&mut t, ts::ctx(&mut s));
        ts::return_shared(t);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = E_ALREADY_FINALIZED, location = kodok_kodok::tournament)]
fun test_finalize_twice_fails() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    expire_tournament(&mut s);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        tournament::finalize_tournament(&mut t, ts::ctx(&mut s));
        tournament::finalize_tournament(&mut t, ts::ctx(&mut s)); // aborts
        ts::return_shared(t);
    };
    ts::end(s);
}

// ============================================================================
// get_leaderboard
// ============================================================================

#[test]
fun test_leaderboard_sorted_by_net_pnl_descending() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    player_join(&mut s, PLAYER1);
    player_join(&mut s, PLAYER2);
    player_join(&mut s, PLAYER3);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t = ts::take_shared<Tournament>(&mut s);
        // PLAYER1 net +50, PLAYER2 net +300, PLAYER3 net +150
        tournament::set_player_stats_for_testing(&mut t, PLAYER1,  50, 0);
        tournament::set_player_stats_for_testing(&mut t, PLAYER2, 300, 0);
        tournament::set_player_stats_for_testing(&mut t, PLAYER3, 150, 0);

        let board = tournament::get_leaderboard(&t);
        assert!(board.length() == 3);

        let e0 = &board[0];
        let e1 = &board[1];
        let e2 = &board[2];
        assert!(tournament::entry_rank(e0) == 1 && tournament::entry_player(e0) == PLAYER2 && tournament::entry_profit(e0) == 300);
        assert!(tournament::entry_rank(e1) == 2 && tournament::entry_player(e1) == PLAYER3 && tournament::entry_profit(e1) == 150);
        assert!(tournament::entry_rank(e2) == 3 && tournament::entry_player(e2) == PLAYER1 && tournament::entry_profit(e2) == 50);

        ts::return_shared(t);
    };
    ts::end(s);
}

#[test]
fun test_leaderboard_capped_at_10() {
    let mut s = ts::begin(ADMIN);
    ts::next_tx(&mut s, ADMIN);
    tournament::init_for_testing(ts::ctx(&mut s));

    ts::next_tx(&mut s, ADMIN);
    {
        let admin = ts::take_from_sender<TournamentAdmin>(&mut s);
        tournament::create_tournament(&admin, WEEK_MS, ts::ctx(&mut s));
        ts::return_to_sender(&mut s, admin);
    };

    let players = vector[
        @0xB1, @0xB2, @0xB3, @0xB4, @0xB5, @0xB6,
        @0xB7, @0xB8, @0xB9, @0xBA, @0xBB, @0xBC,
    ];
    let mut i = 0u64;
    while (i < players.length()) {
        let p = players[i];
        ts::next_tx(&mut s, p);
        {
            let mut t = ts::take_shared<Tournament>(&mut s);
            let fee   = coin::mint_for_testing<HACKATHON>(ENTRY_FEE, ts::ctx(&mut s));
            tournament::join_tournament(&mut t, fee, ts::ctx(&mut s));
            ts::return_shared(t);
        };
        i = i + 1;
    };

    ts::next_tx(&mut s, ADMIN);
    {
        let t = ts::take_shared<Tournament>(&s);
        assert!(tournament::player_count(&t) == 12);
        assert!(tournament::get_leaderboard(&t).length() == 10);
        ts::return_shared(t);
    };
    ts::end(s);
}

#[test]
fun test_leaderboard_empty_when_no_players() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);

    ts::next_tx(&mut s, ADMIN);
    {
        let t = ts::take_shared<Tournament>(&s);
        assert!(tournament::get_leaderboard(&t).length() == 0);
        ts::return_shared(t);
    };
    ts::end(s);
}

// ============================================================================
// Admin: withdraw_remaining
// ============================================================================

#[test]
fun test_withdraw_remaining_after_finalize() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    expire_tournament(&mut s);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut t   = ts::take_shared<Tournament>(&mut s);
        let admin   = ts::take_from_sender<TournamentAdmin>(&mut s);
        tournament::finalize_tournament(&mut t, ts::ctx(&mut s));
        tournament::withdraw_remaining(&admin, &mut t, ts::ctx(&mut s));
        assert!(tournament::prize_pool(&t) == 0);
        ts::return_shared(t);
        ts::return_to_sender(&mut s, admin);
    };
    ts::end(s);
}
