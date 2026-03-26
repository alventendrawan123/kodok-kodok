/// Prediction Market untuk Kodok-Kodok.
///
/// Alur:
///   Admin membuat market dengan pertanyaan + opsi jawaban + resolve_time.
///   Player memanggil `place_prediction` → menyetor HACKATHON ke salah satu opsi.
///   Admin memanggil `resolve_market` → menentukan opsi pemenang.
///   Pemenang memanggil `claim_winnings` → mendapat payout proporsional.
///
/// Formula payout (97% dari total pool; 3% fee untuk admin):
///   payout = user_amount × total_at_resolve × 97 / (winning_pool × 100)
///
/// Catatan implementasi:
///   • `option_pools` menyimpan JUMLAH (u64) bukan Balance agar tidak terjadi
///     double-holding coin; semua coin nyata ada di `total_pool`.
///   • `total_at_resolve` di-snapshot saat resolve agar payout setiap pemenang
///     dihitung dari pool yang sama meskipun dipanggil bertahap.
///   • `claim_winnings` mengonsumsi `UserPrediction` (by-value) sehingga
///     double-claim secara otomatis mustahil tanpa perlu field `claimed`.
module kodok_kodok::prediction;

use std::string::String;
use hackathon::hackathon::HACKATHON;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;

// ============================================================================
// Constants
// ============================================================================

/// Jumlah minimum dan maksimum opsi per market.
const MIN_OPTIONS: u64 = 2;
const MAX_OPTIONS: u64 = 8;

// Error codes
const E_INVALID_OPTIONS:     u64 = 0;
const E_MARKET_RESOLVED:     u64 = 1;
const E_MARKET_NOT_RESOLVED: u64 = 2;
const E_INVALID_OPTION:      u64 = 3;
const E_WRONG_MARKET:        u64 = 4;
const E_NOT_WINNER:          u64 = 5;
const E_ZERO_PAYMENT:        u64 = 6;
const E_NO_WINNING_BETS:     u64 = 7;
const E_RESOLVE_TOO_EARLY:   u64 = 8;

// ============================================================================
// Structs
// ============================================================================

/// Admin capability — dikirim ke deployer saat init.
public struct PredictionAdmin has key {
    id: UID,
}

/// Sebuah prediction market. Shared object.
///
/// `option_pools`    — MIST yang dipertaruhkan per opsi (hanya jumlah, bukan Balance).
///                     Semua coin nyata tersimpan di `total_pool`.
/// `total_pool`      — semua coin yang masuk dari semua player.
/// `total_at_resolve`— snapshot `total_pool.value()` saat market diselesaikan,
///                     digunakan sebagai pembilang payout agar konsisten.
public struct Market has key {
    id: UID,
    question: String,
    options: vector<String>,
    option_pools: vector<u64>,
    total_pool: Balance<HACKATHON>,
    total_at_resolve: u64,
    resolve_time: u64,
    resolved: bool,
    winning_option: Option<u8>,
}

/// Bukti kepemilikan prediction — dimiliki player, dikonsumsi saat klaim.
/// Field `claimed` ada sesuai spec; double-claim dicegah oleh konsumsi objek.
public struct UserPrediction has key {
    id: UID,
    market_id: ID,
    option_index: u8,
    amount: u64,
    claimed: bool,
}

// ============================================================================
// Events
// ============================================================================

public struct MarketCreated has copy, drop {
    market_id: ID,
    question: String,
    options_count: u64,
    resolve_time: u64,
}

public struct PredictionPlaced has copy, drop {
    market_id: ID,
    player: address,
    option_index: u8,
    amount: u64,
}

public struct MarketResolved has copy, drop {
    market_id: ID,
    winning_option: u8,
    total_pool: u64,
}

public struct WinningsClaimed has copy, drop {
    market_id: ID,
    player: address,
    payout: u64,
}

// ============================================================================
// Module Initializer
// ============================================================================

fun init(ctx: &mut TxContext) {
    transfer::transfer(
        PredictionAdmin { id: object::new(ctx) },
        ctx.sender(),
    );
}

// ============================================================================
// Public Functions — Admin
// ============================================================================

/// Buat market baru.
///
/// `question`     — pertanyaan yang diajukan (misal "Tim mana yang menang?").
/// `options`      — vektor jawaban (min 2, max 8).
/// `resolve_time` — epoch_timestamp_ms kapan market bisa diselesaikan.
public fun create_market(
    _admin: &PredictionAdmin,
    question: String,
    options: vector<String>,
    resolve_time: u64,
    ctx: &mut TxContext,
) {
    let n = options.length();
    assert!(n >= MIN_OPTIONS && n <= MAX_OPTIONS, E_INVALID_OPTIONS);

    // Inisialisasi pools per opsi dengan 0
    let mut option_pools: vector<u64> = vector[];
    let mut i = 0;
    while (i < n) {
        option_pools.push_back(0u64);
        i = i + 1;
    };

    let market = Market {
        id: object::new(ctx),
        question,
        options,
        option_pools,
        total_pool: balance::zero(),
        total_at_resolve: 0,
        resolve_time,
        resolved: false,
        winning_option: option::none(),
    };

    let market_id = object::id(&market);
    event::emit(MarketCreated {
        market_id,
        question: market.question,
        options_count: n,
        resolve_time,
    });

    transfer::share_object(market);
}

/// Tentukan opsi pemenang dan tutup market.
/// Hanya bisa dipanggil setelah `resolve_time` berlalu.
///
/// `winning_option` — index opsi yang menang (0-based).
///                    Harus ada setidaknya satu player yang memilih opsi ini.
public fun resolve_market(
    _admin: &PredictionAdmin,
    market: &mut Market,
    winning_option: u8,
    ctx: &TxContext,
) {
    assert!(!market.resolved, E_MARKET_RESOLVED);
    assert!((winning_option as u64) < market.options.length(), E_INVALID_OPTION);
    assert!(ctx.epoch_timestamp_ms() >= market.resolve_time, E_RESOLVE_TOO_EARLY);
    assert!(*market.option_pools.borrow(winning_option as u64) > 0, E_NO_WINNING_BETS);

    let total = market.total_pool.value();
    market.total_at_resolve = total;
    market.resolved = true;
    market.winning_option = option::some(winning_option);

    event::emit(MarketResolved {
        market_id: object::id(market),
        winning_option,
        total_pool: total,
    });
}

// ============================================================================
// Public Functions — Player
// ============================================================================

/// Pasang prediksi pada salah satu opsi.
///
/// `option_index` — opsi yang dipilih (0-based, harus < jumlah opsi).
/// `payment`      — jumlah HACKATHON yang dipertaruhkan (> 0).
///
/// `UserPrediction` langsung di-transfer ke sender (key-only, tidak punya store).
#[allow(lint(self_transfer))]
public fun place_prediction(
    market: &mut Market,
    option_index: u8,
    payment: Coin<HACKATHON>,
    ctx: &mut TxContext,
) {
    assert!(!market.resolved, E_MARKET_RESOLVED);
    assert!((option_index as u64) < market.options.length(), E_INVALID_OPTION);
    assert!(payment.value() > 0, E_ZERO_PAYMENT);

    let amount    = payment.value();
    let player    = ctx.sender();
    let market_id = object::id(market);

    let idx       = option_index as u64;
    let old_total = *market.option_pools.borrow(idx);
    *market.option_pools.borrow_mut(idx) = old_total + amount;
    market.total_pool.join(payment.into_balance());

    event::emit(PredictionPlaced { market_id, player, option_index, amount });

    transfer::transfer(
        UserPrediction {
            id: object::new(ctx),
            market_id,
            option_index,
            amount,
            claimed: false,
        },
        player,
    );
}

/// Klaim kemenangan. Mengonsumsi `UserPrediction` (satu kali pakai).
///
/// Payout = user_amount × total_at_resolve × 97 / (winning_pool × 100)
/// Sisa 3% tetap di market sebagai fee.
///
/// Syarat:
///   • Market sudah diselesaikan.
///   • Prediction adalah untuk market ini.
///   • Opsi yang dipilih adalah opsi pemenang.
#[allow(lint(self_transfer))]
public fun claim_winnings(
    market: &mut Market,
    prediction: UserPrediction,
    ctx: &mut TxContext,
) {
    assert!(market.resolved, E_MARKET_NOT_RESOLVED);

    let winning_option = *market.winning_option.borrow();

    // Konsumsi UserPrediction — mencegah double-claim secara otomatis
    let UserPrediction { id, market_id, option_index, amount, claimed: _ } = prediction;
    id.delete();

    assert!(market_id == object::id(market), E_WRONG_MARKET);
    assert!(option_index == winning_option, E_NOT_WINNER);

    let winning_pool = *market.option_pools.borrow(winning_option as u64);

    // Hitung payout dengan u128 untuk mencegah overflow
    // payout = amount × total_at_resolve × 97 / (winning_pool × 100)
    let payout = (
        (amount as u128)
            * (market.total_at_resolve as u128)
            * 97u128
            / ((winning_pool as u128) * 100u128)
    ) as u64;

    let player = ctx.sender();

    if (payout > 0 && market.total_pool.value() >= payout) {
        let winnings = market.total_pool.split(payout);
        transfer::public_transfer(coin::from_balance(winnings, ctx), player);
    };

    event::emit(WinningsClaimed {
        market_id: object::id(market),
        player,
        payout,
    });
}

// ============================================================================
// View Functions
// ============================================================================

public fun market_question(m: &Market): String           { m.question }
public fun market_is_resolved(m: &Market): bool          { m.resolved }
public fun market_resolve_time(m: &Market): u64          { m.resolve_time }
public fun market_total_pool(m: &Market): u64            { m.total_pool.value() }
public fun market_total_at_resolve(m: &Market): u64      { m.total_at_resolve }
public fun market_winning_option(m: &Market): Option<u8> { m.winning_option }
public fun market_options_count(m: &Market): u64         { m.options.length() }

/// Jumlah MIST yang dipertaruhkan pada opsi ke-`i`.
public fun market_option_pool(m: &Market, i: u64): u64 {
    *m.option_pools.borrow(i)
}

public fun prediction_market_id(p: &UserPrediction): ID   { p.market_id }
public fun prediction_option_index(p: &UserPrediction): u8 { p.option_index }
public fun prediction_amount(p: &UserPrediction): u64      { p.amount }

// ============================================================================
// Test Helpers
// ============================================================================

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

/// Expose error constants untuk #[expected_failure] di test.
#[test_only] public fun e_invalid_options(): u64     { E_INVALID_OPTIONS }
#[test_only] public fun e_market_resolved(): u64     { E_MARKET_RESOLVED }
#[test_only] public fun e_market_not_resolved(): u64 { E_MARKET_NOT_RESOLVED }
#[test_only] public fun e_invalid_option(): u64      { E_INVALID_OPTION }
#[test_only] public fun e_wrong_market(): u64        { E_WRONG_MARKET }
#[test_only] public fun e_not_winner(): u64          { E_NOT_WINNER }
#[test_only] public fun e_zero_payment(): u64        { E_ZERO_PAYMENT }
#[test_only] public fun e_no_winning_bets(): u64     { E_NO_WINNING_BETS }
#[test_only] public fun e_resolve_too_early(): u64   { E_RESOLVE_TOO_EARLY }
