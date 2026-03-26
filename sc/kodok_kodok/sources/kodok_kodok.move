/// Kodok-Kodok: on-chain Crown-and-Anchor dice game on OneChain.
///
/// Symbols : KODOK=0  KEPITING=1  IKAN=2  UDANG=3  LABU=4  RODA=5
/// Dice    : 3 per round
/// Payout  : 0 match → lose | 1 match → 2x | 2 match → 3x | 3 match → 4x
/// House edge: −17/216 ≈ −7.87% (standard Crown-and-Anchor probability)
///
/// NOTE: Randomness uses keccak256(fresh_address ‖ epoch) — suitable for
/// hackathon demo. For production, integrate a native VRF from the OneChain team.
module kodok_kodok::kodok_kodok;

use std::bcs;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::hash;
use hackathon::hackathon::HACKATHON;
use kodok_kodok::tournament::{Tournament, record_round_result};

// =========================================================================
// Constants
// =========================================================================

/// Valid symbols: 0..5
const SYMBOL_COUNT: u8 = 6;

// Error codes
const E_GAME_PAUSED:              u64 = 0;
const E_INVALID_SYMBOL:           u64 = 1;
const E_INSUFFICIENT_PAYMENT:     u64 = 2;
const E_INSUFFICIENT_HOUSE_FUNDS: u64 = 3;
const E_INVALID_BETS:             u64 = 4;

// =========================================================================
// Structs
// =========================================================================

/// Admin capability — transferred to deployer at init. Never shared.
/// Pass `&GameAdmin` to authorize privileged operations.
public struct GameAdmin has key {
    id: UID,
}

/// Global game state — shared object; all players read/write it.
public struct GameState has key {
    id: UID,
    house_balance: Balance<HACKATHON>,
    total_rounds: u64,
    paused: bool,
}

/// One bet on a single symbol.
public struct Bet has store, copy, drop {
    symbol_id: u8,
    amount: u64,
}

/// Proof-of-bet owned by the player while the round is pending.
/// Must be consumed exactly once via `resolve_round`.
public struct BetReceipt has key {
    id: UID,
    player: address,
    bets: vector<Bet>,
    total_bet: u64,
}

// =========================================================================
// Events
// =========================================================================

public struct BetsPlaced has copy, drop {
    player: address,
    total_bet: u64,
}

public struct RoundResult has copy, drop {
    player: address,
    dice: vector<u8>,   // [die0, die1, die2], each in 0..5
    payout: u64,
    total_bet: u64,     // frontend computes net_pnl = payout - total_bet (signed)
}

// =========================================================================
// Module Initializer
// =========================================================================

/// Called once at publish time.
/// Creates the admin cap (owned by deployer) and shared game state.
fun init(ctx: &mut TxContext) {
    transfer::transfer(
        GameAdmin { id: object::new(ctx) },
        ctx.sender(),
    );
    transfer::share_object(GameState {
        id: object::new(ctx),
        house_balance: balance::zero(),
        total_rounds: 0,
        paused: false,
    });
}

// =========================================================================
// Public Functions — Player
// =========================================================================

/// Place bets on one or more symbols (1–6).
///
/// `symbols`  — list of symbol IDs (0–5); duplicates allowed (bet twice on
///              same symbol if desired).
/// `payment`  — total HACKATHON to wager; split equally across all symbols.
///
/// Returns an owned `BetReceipt` that must be passed to `resolve_round`.
public fun place_bets(
    game: &mut GameState,
    symbols: vector<u8>,
    payment: Coin<HACKATHON>,
    ctx: &mut TxContext,
): BetReceipt {
    assert!(!game.paused, E_GAME_PAUSED);

    let n = symbols.length();
    assert!(n > 0 && n <= 6, E_INVALID_BETS);

    let total_payment = payment.value();
    let bet_amount = total_payment / n;          // integer division; dust stays in house
    assert!(bet_amount > 0, E_INSUFFICIENT_PAYMENT);

    // Validate every symbol is in [0, SYMBOL_COUNT)
    let mut i = 0;
    while (i < n) {
        assert!(symbols[i] < SYMBOL_COUNT, E_INVALID_SYMBOL);
        i = i + 1;
    };

    // Build per-symbol bets
    let mut bets: vector<Bet> = vector[];
    let mut i = 0;
    while (i < n) {
        bets.push_back(Bet { symbol_id: symbols[i], amount: bet_amount });
        i = i + 1;
    };

    let total_bet = bet_amount * n;
    let player = ctx.sender();

    // House holds the funds until resolve_round is called
    game.house_balance.join(payment.into_balance());

    event::emit(BetsPlaced { player, total_bet });

    BetReceipt {
        id: object::new(ctx),
        player,
        bets,
        total_bet,
    }
}

/// Resolve the round: roll 3 dice, compute payout, pay out any winnings.
/// Consumes the `BetReceipt` (one-time use).
///
/// `random_seed` — optional extra entropy from the caller (e.g. frontend nonce).
///                 Mixed in with on-chain sources so neither party alone controls the outcome.
///
/// Payout per bet on symbol S:
///   count = number of dice showing S
///   0 → 0 (lose)   1 → 2× bet   2 → 3× bet   3 → 4× bet
///
/// Net house edge ≈ −7.87% built into the probability structure.
public fun resolve_round(
    game: &mut GameState,
    receipt: BetReceipt,
    random_seed: vector<u8>,
    ctx: &mut TxContext,
) {
    do_resolve(game, receipt, random_seed, ctx);
}

/// Same as `resolve_round` but also records the P&L in the tournament.
/// Safe to call even if the player has not joined the tournament — it silently skips.
public fun resolve_round_with_tournament(
    game: &mut GameState,
    tourn: &mut Tournament,
    receipt: BetReceipt,
    random_seed: vector<u8>,
    ctx: &mut TxContext,
) {
    let (payout, total_bet, player) = do_resolve(game, receipt, random_seed, ctx);
    let profit = if (payout > total_bet) { payout - total_bet } else { 0 };
    let loss   = if (total_bet > payout) { total_bet - payout } else { 0 };
    record_round_result(tourn, player, profit, loss);
}

fun do_resolve(
    game: &mut GameState,
    receipt: BetReceipt,
    random_seed: vector<u8>,
    ctx: &mut TxContext,
): (u64, u64, address) {
    // ── Hash-based pseudo-RNG ───────────────────────────────────────────────
    let mut seed = bcs::to_bytes(&ctx.fresh_object_address());
    seed.append(bcs::to_bytes(&ctx.epoch()));
    seed.append(random_seed);
    let h = hash::keccak256(&seed);

    let dice = vector[h[0] % 6, h[1] % 6, h[2] % 6];

    // ── Destructure & delete receipt ────────────────────────────────────────
    let BetReceipt { id, player, bets, total_bet } = receipt;
    id.delete();

    // ── Payout ──────────────────────────────────────────────────────────────
    let total_payout = calculate_payout(&bets, &dice);
    game.total_rounds = game.total_rounds + 1;

    event::emit(RoundResult { player, dice, payout: total_payout, total_bet });

    // ── Transfer winnings ───────────────────────────────────────────────────
    if (total_payout > 0) {
        assert!(game.house_balance.value() >= total_payout, E_INSUFFICIENT_HOUSE_FUNDS);
        let winnings = game.house_balance.split(total_payout);
        transfer::public_transfer(coin::from_balance(winnings, ctx), player);
    };

    (total_payout, total_bet, player)
}

// =========================================================================
// Public Functions — Admin
// =========================================================================

/// Deposit HACKATHON into the house treasury so it can cover payouts.
public fun fund_house(
    _admin: &GameAdmin,
    game: &mut GameState,
    payment: Coin<HACKATHON>,
) {
    game.house_balance.join(payment.into_balance());
}

/// Withdraw HACKATHON from the house treasury to the admin's wallet.
#[allow(lint(self_transfer))]
public fun withdraw_house(
    _admin: &GameAdmin,
    game: &mut GameState,
    amount: u64,
    ctx: &mut TxContext,
) {
    let funds = game.house_balance.split(amount);
    transfer::public_transfer(coin::from_balance(funds, ctx), ctx.sender());
}

/// Pause new bets (existing receipts can still be resolved).
public fun pause(_admin: &GameAdmin, game: &mut GameState) {
    game.paused = true;
}

/// Resume new bets.
public fun unpause(_admin: &GameAdmin, game: &mut GameState) {
    game.paused = false;
}

// =========================================================================
// View Functions
// =========================================================================

public fun house_balance(game: &GameState): u64  { game.house_balance.value() }
public fun is_paused(game: &GameState): bool     { game.paused }
public fun total_rounds(game: &GameState): u64   { game.total_rounds }

// =========================================================================
// Private Helpers
// =========================================================================

/// For each bet, count how many dice show that symbol.
/// 0 matches → 0 | n matches → (n+1) × bet.amount
fun calculate_payout(bets: &vector<Bet>, dice: &vector<u8>): u64 {
    let mut total = 0u64;
    let mut i = 0;
    while (i < bets.length()) {
        let bet = bets[i];
        let mut matches = 0u64;
        let mut j = 0;
        while (j < 3) {
            if (dice[j] == bet.symbol_id) {
                matches = matches + 1;
            };
            j = j + 1;
        };
        if (matches > 0) {
            total = total + (matches + 1) * bet.amount;
        };
        i = i + 1;
    };
    total
}

// =========================================================================
// Test-Only Helpers
// =========================================================================

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

/// Expose payout calculator for deterministic unit tests.
#[test_only]
public fun calculate_payout_for_testing(bets: &vector<Bet>, dice: &vector<u8>): u64 {
    calculate_payout(bets, dice)
}

/// Construct a Bet directly for test assertions.
#[test_only]
public fun new_bet(symbol_id: u8, amount: u64): Bet {
    Bet { symbol_id, amount }
}

/// Destroy a receipt — used in error tests where the abort means the receipt
/// is never actually created, but the compiler still needs to see valid disposal
/// of the value (transfer::transfer/public_transfer both refuse cross-module use
/// for key-only objects).
#[test_only]
public fun destroy_receipt_for_testing(receipt: BetReceipt) {
    let BetReceipt { id, player: _, bets: _, total_bet: _ } = receipt;
    id.delete();
}

/// Expose error constants for #[expected_failure] annotations in tests.
#[test_only] public fun e_game_paused(): u64              { E_GAME_PAUSED }
#[test_only] public fun e_invalid_symbol(): u64           { E_INVALID_SYMBOL }
#[test_only] public fun e_insufficient_payment(): u64     { E_INSUFFICIENT_PAYMENT }
#[test_only] public fun e_insufficient_house_funds(): u64 { E_INSUFFICIENT_HOUSE_FUNDS }
#[test_only] public fun e_invalid_bets(): u64             { E_INVALID_BETS }
