/// Unit tests for kodok_kodok game contract.
///
/// Payout formula (per bet):
///   0 match  → 0
///   1 match  → 2 × amount
///   2 match  → 3 × amount
///   3 match  → 4 × amount
///
/// Expected house edge (full-round average): −17/216 ≈ −7.87%
#[test_only]
#[allow(unused_mut_ref, unused_const)]
module kodok_kodok::kodok_kodok_tests;

use sui::coin;
use sui::test_scenario as ts;
use hackathon::hackathon::HACKATHON;
use kodok_kodok::kodok_kodok::{
    Self,
    GameAdmin,
    GameState,
};

// =========================================================================
// Test fixtures
// =========================================================================

const ADMIN:  address = @0xAD;
const PLAYER: address = @0xA1;
const MIST:   u64     = 1_000_000_000; // 1 HKT

// Error codes mirrored from kodok_kodok.move for #[expected_failure] annotations.
// #[expected_failure] only accepts u64 literals or named constants in the same module.
const E_GAME_PAUSED:    u64 = 0;
const E_INVALID_SYMBOL: u64 = 1;
const E_INVALID_BETS:   u64 = 4;

/// Deploy the contract and pre-fund the house with `house_hkt` HKT.
fun setup(scenario: &mut ts::Scenario, house_oct: u64) {
    ts::next_tx(scenario, ADMIN);
    kodok_kodok::init_for_testing(ts::ctx(scenario));

    ts::next_tx(scenario, ADMIN);
    {
        let mut game = ts::take_shared<GameState>(scenario);
        let admin    = ts::take_from_sender<GameAdmin>(scenario);
        let deposit  = coin::mint_for_testing<HACKATHON>(house_oct * MIST, ts::ctx(scenario));
        kodok_kodok::fund_house(&admin, &mut game, deposit);
        ts::return_shared(game);
        ts::return_to_sender(scenario, admin);
    };
}

// =========================================================================
// Payout calculation — deterministic tests (no on-chain randomness needed)
// =========================================================================

#[test]
fun test_payout_no_match() {
    // KODOK(0) bet, dice show no KODOK → 0 payout
    let bets = vector[kodok_kodok::new_bet(0, 1_000_000)];
    let dice = vector[1u8, 2u8, 3u8];
    let payout = kodok_kodok::calculate_payout_for_testing(&bets, &dice);
    assert!(payout == 0);
}

#[test]
fun test_payout_one_match() {
    // KODOK(0) bet, one KODOK in dice → 2× amount
    let amount = 1_000_000u64;
    let bets = vector[kodok_kodok::new_bet(0, amount)];
    let dice = vector[0u8, 1u8, 2u8];
    let payout = kodok_kodok::calculate_payout_for_testing(&bets, &dice);
    assert!(payout == 2 * amount);
}

#[test]
fun test_payout_two_matches() {
    // KEPITING(1) bet, two KEPITING in dice → 3× amount
    let amount = 1_000_000u64;
    let bets = vector[kodok_kodok::new_bet(1, amount)];
    let dice = vector[1u8, 1u8, 0u8];
    let payout = kodok_kodok::calculate_payout_for_testing(&bets, &dice);
    assert!(payout == 3 * amount);
}

#[test]
fun test_payout_three_matches() {
    // RODA(5) bet, all three dice show RODA → 4× amount
    let amount = 1_000_000u64;
    let bets = vector[kodok_kodok::new_bet(5, amount)];
    let dice = vector[5u8, 5u8, 5u8];
    let payout = kodok_kodok::calculate_payout_for_testing(&bets, &dice);
    assert!(payout == 4 * amount);
}

#[test]
fun test_payout_multi_bet_mixed() {
    // Bet on KODOK(0), KEPITING(1), IKAN(2) — 1_000_000 each
    // Dice: [0, 1, 5]  →  KODOK hits (1×), KEPITING hits (1×), IKAN misses
    let a = 1_000_000u64;
    let bets = vector[
        kodok_kodok::new_bet(0, a),
        kodok_kodok::new_bet(1, a),
        kodok_kodok::new_bet(2, a),
    ];
    let dice = vector[0u8, 1u8, 5u8];
    let payout = kodok_kodok::calculate_payout_for_testing(&bets, &dice);
    // KODOK: 2a  +  KEPITING: 2a  +  IKAN: 0  = 4a
    assert!(payout == 4 * a);
}

#[test]
fun test_payout_all_symbols_three_hits() {
    // 6 symbols bet — dice [0,1,2] → symbols 0,1,2 each get 1 match
    let a = 500_000u64;
    let bets = vector[
        kodok_kodok::new_bet(0, a),
        kodok_kodok::new_bet(1, a),
        kodok_kodok::new_bet(2, a),
        kodok_kodok::new_bet(3, a),
        kodok_kodok::new_bet(4, a),
        kodok_kodok::new_bet(5, a),
    ];
    let dice = vector[0u8, 1u8, 2u8];
    let payout = kodok_kodok::calculate_payout_for_testing(&bets, &dice);
    // 3 symbols hit (1× each) → 3 × 2a = 6a
    assert!(payout == 6 * a);
}

// =========================================================================
// Lifecycle: init
// =========================================================================

#[test]
fun test_init_state() {
    let mut s = ts::begin(ADMIN);
    ts::next_tx(&mut s, ADMIN);
    kodok_kodok::init_for_testing(ts::ctx(&mut s));

    ts::next_tx(&mut s, ADMIN);
    {
        assert!(ts::has_most_recent_for_sender<GameAdmin>(&s));
        let game = ts::take_shared<GameState>(&s);
        assert!(!kodok_kodok::is_paused(&game));
        assert!(kodok_kodok::house_balance(&game) == 0);
        assert!(kodok_kodok::total_rounds(&game) == 0);
        ts::return_shared(game);
    };
    ts::end(s);
}

// =========================================================================
// Admin: fund & withdraw
// =========================================================================

#[test]
fun test_fund_and_withdraw() {
    let mut s = ts::begin(ADMIN);
    ts::next_tx(&mut s, ADMIN);
    kodok_kodok::init_for_testing(ts::ctx(&mut s));

    ts::next_tx(&mut s, ADMIN);
    {
        let mut game = ts::take_shared<GameState>(&mut s);
        let admin    = ts::take_from_sender<GameAdmin>(&mut s);

        let dep = coin::mint_for_testing<HACKATHON>(10 * MIST, ts::ctx(&mut s));
        kodok_kodok::fund_house(&admin, &mut game, dep);
        assert!(kodok_kodok::house_balance(&game) == 10 * MIST);

        kodok_kodok::withdraw_house(&admin, &mut game, 4 * MIST, ts::ctx(&mut s));
        assert!(kodok_kodok::house_balance(&game) == 6 * MIST);

        ts::return_shared(game);
        ts::return_to_sender(&mut s, admin);
    };
    ts::end(s);
}

// =========================================================================
// Admin: pause / unpause
// =========================================================================

#[test]
fun test_pause_unpause() {
    let mut s = ts::begin(ADMIN);
    ts::next_tx(&mut s, ADMIN);
    kodok_kodok::init_for_testing(ts::ctx(&mut s));

    ts::next_tx(&mut s, ADMIN);
    {
        let mut game = ts::take_shared<GameState>(&mut s);
        let admin    = ts::take_from_sender<GameAdmin>(&mut s);

        kodok_kodok::pause(&admin, &mut game);
        assert!(kodok_kodok::is_paused(&game));

        kodok_kodok::unpause(&admin, &mut game);
        assert!(!kodok_kodok::is_paused(&game));

        ts::return_shared(game);
        ts::return_to_sender(&mut s, admin);
    };
    ts::end(s);
}

// =========================================================================
// Full flow: place_bets → resolve_round
// =========================================================================

#[test]
fun test_place_and_resolve_increments_rounds() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s, 100); // house has 100 HKT

    ts::next_tx(&mut s, PLAYER);
    {
        let mut game = ts::take_shared<GameState>(&mut s);
        let c = coin::mint_for_testing<HACKATHON>(MIST, ts::ctx(&mut s));

        let receipt = kodok_kodok::place_bets(
            &mut game,
            vector[0u8],
            c,
            ts::ctx(&mut s),
        );
        assert!(kodok_kodok::house_balance(&game) >= MIST);

        kodok_kodok::resolve_round(&mut game, receipt, vector[], ts::ctx(&mut s));
        assert!(kodok_kodok::total_rounds(&game) == 1);

        ts::return_shared(game);
    };
    ts::end(s);
}

#[test]
fun test_payment_split_equally_across_symbols() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s, 100);

    ts::next_tx(&mut s, PLAYER);
    {
        let mut game   = ts::take_shared<GameState>(&mut s);
        let initial    = kodok_kodok::house_balance(&game);
        let c = coin::mint_for_testing<HACKATHON>(3 * MIST, ts::ctx(&mut s));

        // 3 HKT bet across 3 symbols → 1 HKT each
        let receipt = kodok_kodok::place_bets(
            &mut game,
            vector[0u8, 1u8, 2u8],
            c,
            ts::ctx(&mut s),
        );
        assert!(kodok_kodok::house_balance(&game) == initial + 3 * MIST);

        kodok_kodok::resolve_round(&mut game, receipt, vector[], ts::ctx(&mut s));
        ts::return_shared(game);
    };
    ts::end(s);
}

#[test]
fun test_multiple_rounds_counter() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s, 100);

    let mut round = 0u64;
    while (round < 3) {
        ts::next_tx(&mut s, PLAYER);
        {
            let mut game = ts::take_shared<GameState>(&mut s);
            let c = coin::mint_for_testing<HACKATHON>(MIST, ts::ctx(&mut s));
            let r = kodok_kodok::place_bets(&mut game, vector[0u8], c, ts::ctx(&mut s));
            kodok_kodok::resolve_round(&mut game, r, vector[], ts::ctx(&mut s));
            ts::return_shared(game);
        };
        round = round + 1;
    };

    ts::next_tx(&mut s, PLAYER);
    {
        let game = ts::take_shared<GameState>(&mut s);
        assert!(kodok_kodok::total_rounds(&game) == 3);
        ts::return_shared(game);
    };
    ts::end(s);
}

// =========================================================================
// Error cases
// =========================================================================

#[test]
#[expected_failure(abort_code = E_GAME_PAUSED, location = 0x0::kodok_kodok)]
fun test_place_bets_fails_when_paused() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s, 100);

    ts::next_tx(&mut s, ADMIN);
    {
        let mut game = ts::take_shared<GameState>(&mut s);
        let admin    = ts::take_from_sender<GameAdmin>(&mut s);
        kodok_kodok::pause(&admin, &mut game);
        ts::return_shared(game);
        ts::return_to_sender(&mut s, admin);
    };

    ts::next_tx(&mut s, PLAYER);
    {
        let mut game = ts::take_shared<GameState>(&mut s);
        let c = coin::mint_for_testing<HACKATHON>(MIST, ts::ctx(&mut s));
        // ← aborts here with E_GAME_PAUSED; receipt is never created
        let receipt = kodok_kodok::place_bets(&mut game, vector[0u8], c, ts::ctx(&mut s));
        // Unreachable — transfer prevents "unused value" compile error
        kodok_kodok::destroy_receipt_for_testing(receipt);
        ts::return_shared(game);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = E_INVALID_SYMBOL, location = 0x0::kodok_kodok)]
fun test_place_bets_fails_invalid_symbol() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s, 100);

    ts::next_tx(&mut s, PLAYER);
    {
        let mut game = ts::take_shared<GameState>(&mut s);
        let c = coin::mint_for_testing<HACKATHON>(MIST, ts::ctx(&mut s));
        // symbol 9 out of range [0,5] → E_INVALID_SYMBOL
        let receipt = kodok_kodok::place_bets(&mut game, vector[9u8], c, ts::ctx(&mut s));
        kodok_kodok::destroy_receipt_for_testing(receipt);
        ts::return_shared(game);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = E_INVALID_BETS, location = 0x0::kodok_kodok)]
fun test_place_bets_fails_empty_symbols() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s, 100);

    ts::next_tx(&mut s, PLAYER);
    {
        let mut game = ts::take_shared<GameState>(&mut s);
        let c = coin::mint_for_testing<HACKATHON>(MIST, ts::ctx(&mut s));
        // empty symbols → E_INVALID_BETS
        let receipt = kodok_kodok::place_bets(&mut game, vector[], c, ts::ctx(&mut s));
        kodok_kodok::destroy_receipt_for_testing(receipt);
        ts::return_shared(game);
    };
    ts::end(s);
}
