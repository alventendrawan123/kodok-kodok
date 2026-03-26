/// Social Table — fitur player-as-banker untuk Kodok-Kodok.
///
/// Alur:
///   Banker memanggil `open_table` → deposit ≥50 HKT sebagai collateral.
///   Player memanggil `place_bets_at_table` → payment masuk ke collateral meja.
///   Banker memanggil `roll_dice_at_table` → dadu dikocok, semua bet terselesaikan.
///   Banker memanggil `close_table` → sisa collateral dikembalikan ke banker.
///
/// Aliran collateral:
///   open_table          → banker deposit ≥50 HKT  → collateral
///   place_bets_at_table → payment player           → collateral
///   roll_dice_at_table  → payout pemenang          ← collateral
///   close_table         → sisa collateral          → banker
///
/// Rumus payout (per bet simbol S):
///   jumlah dadu cocok = 0 → 0
///   jumlah dadu cocok = 1 → 2× amount
///   jumlah dadu cocok = 2 → 3× amount
///   jumlah dadu cocok = 3 → 4× amount
module kodok_kodok::social_table;

use std::bcs;
use std::string::String;
use hackathon::hackathon::HACKATHON;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::hash;
use sui::table::{Self, Table};

// ============================================================================
// Constants
// ============================================================================

/// Jumlah simbol valid: KODOK=0  KEPITING=1  IKAN=2  UDANG=3  LABU=4  RODA=5
const SYMBOL_COUNT: u8 = 6;

/// Minimum collateral yang harus disetor banker untuk membuka meja (50 HKT).
const MIN_COLLATERAL: u64 = 50_000_000_000;

// Error codes
const E_INSUFFICIENT_COLLATERAL: u64 = 0;
const E_TABLE_CLOSED:            u64 = 1;
const E_NOT_BANKER:              u64 = 2;
const E_ALREADY_BET:             u64 = 3;
const E_TABLE_FULL:              u64 = 4;
const E_INVALID_SYMBOL:          u64 = 5;
const E_INVALID_BET:             u64 = 6;

// ============================================================================
// Structs
// ============================================================================

/// Shared singleton — registry semua GameTable yang aktif.
public struct TableRegistry has key {
    id: UID,
    /// Peta dari table ID ke metadata ringkas untuk keperluan discovery.
    tables: Table<ID, TableInfo>,
}

/// Metadata ringkas tiap meja yang disimpan dalam registry.
public struct TableInfo has store, drop {
    banker: address,
    open: bool,
}

/// Meja permainan yang dikontrol banker.  Shared object.
///
/// `collateral`   — deposit banker + semua pembayaran player untuk ronde ini.
/// `players`      — player yang sudah bet di ronde ini; menjadi kunci iterasi
///                  karena `Table` tidak mendukung iterator bawaan.
/// `pending_bets` — bet yang belum diresolvekejadian; di-clear setelah roll.
public struct GameTable has key {
    id: UID,
    name: String,
    banker: address,
    collateral: Balance<HACKATHON>,
    min_bet: u64,
    max_players: u8,
    players: vector<address>,
    pending_bets: Table<address, vector<Bet>>,
    open: bool,
}

/// Satu bet pada satu simbol.
public struct Bet has store, copy, drop {
    symbol_id: u8,
    amount: u64,
}

// ============================================================================
// Events
// ============================================================================

public struct TableOpened has copy, drop {
    table_id: ID,
    banker: address,
    name: String,
    min_bet: u64,
    collateral: u64,
}

public struct BetsPlacedAtTable has copy, drop {
    table_id: ID,
    player: address,
    total_bet: u64,
}

public struct DiceRolledAtTable has copy, drop {
    table_id: ID,
    dice: vector<u8>,
    player_count: u64,
}

public struct TableClosed has copy, drop {
    table_id: ID,
    banker: address,
    returned_collateral: u64,
}

// ============================================================================
// Module Initializer
// ============================================================================

/// Dipanggil sekali saat publish. Membuat TableRegistry sebagai shared object.
fun init(ctx: &mut TxContext) {
    transfer::share_object(TableRegistry {
        id: object::new(ctx),
        tables: table::new(ctx),
    });
}

// ============================================================================
// Public Functions — Banker
// ============================================================================

/// Buka meja baru dan deposit collateral.
///
/// `name`        — nama meja (tampil di UI).
/// `min_bet`     — jumlah minimum MIST per bet per simbol.
/// `max_players` — maksimum player yang boleh bet per ronde.
/// `collateral`  — deposit awal; harus ≥ MIN_COLLATERAL (50 HKT).
public fun open_table(
    registry: &mut TableRegistry,
    name: String,
    min_bet: u64,
    max_players: u8,
    collateral: Coin<HACKATHON>,
    ctx: &mut TxContext,
) {
    assert!(collateral.value() >= MIN_COLLATERAL, E_INSUFFICIENT_COLLATERAL);

    let banker = ctx.sender();
    let collateral_amount = collateral.value();

    let game_table = GameTable {
        id: object::new(ctx),
        name,
        banker,
        collateral: collateral.into_balance(),
        min_bet,
        max_players,
        players: vector[],
        pending_bets: table::new(ctx),
        open: true,
    };

    let table_id = object::id(&game_table);
    registry.tables.add(table_id, TableInfo { banker, open: true });

    event::emit(TableOpened {
        table_id,
        banker,
        name: game_table.name,
        min_bet,
        collateral: collateral_amount,
    });

    transfer::share_object(game_table);
}

/// Tutup meja dan kembalikan sisa collateral ke banker.
/// Bet yang belum di-resolve (pending) akan direfund ke masing-masing player.
/// Hanya banker pemilik meja yang boleh memanggil ini.
#[allow(lint(self_transfer))]
public fun close_table(
    registry: &mut TableRegistry,
    table: GameTable,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == table.banker, E_NOT_BANKER);

    let GameTable {
        id,
        name: _,
        banker,
        mut collateral,
        min_bet: _,
        max_players: _,
        mut players,
        mut pending_bets,
        open: _,
    } = table;

    let table_id = object::uid_to_inner(&id);

    // ── Refund semua bet yang belum diresolvekejadian ─────────────────────────
    while (!players.is_empty()) {
        let player     = players.pop_back();
        let bets       = pending_bets.remove(player);
        let refund_amt = sum_bet_amounts(&bets);
        // bets di-drop di sini (Bet has drop → vector<Bet> has drop)

        if (refund_amt > 0 && collateral.value() >= refund_amt) {
            let refund = collateral.split(refund_amt);
            transfer::public_transfer(coin::from_balance(refund, ctx), player);
        };
    };
    table::destroy_empty(pending_bets);

    // ── Kembalikan sisa collateral ke banker ──────────────────────────────────
    let remaining = collateral.value();
    event::emit(TableClosed { table_id, banker, returned_collateral: remaining });

    if (remaining > 0) {
        transfer::public_transfer(coin::from_balance(collateral, ctx), banker);
    } else {
        balance::destroy_zero(collateral);
    };

    // ── Hapus dari registry ───────────────────────────────────────────────────
    if (registry.tables.contains(table_id)) {
        registry.tables.remove(table_id);
        // TableInfo has drop → hasil remove langsung di-drop
    };

    id.delete();
}

// ============================================================================
// Public Functions — Player
// ============================================================================

/// Pasang bet pada satu atau lebih simbol di meja ini.
///
/// `symbols`  — daftar simbol (0–5); boleh duplikat; maksimum 6.
/// `payment`  — total HACKATHON yang dipertaruhkan; dibagi rata ke semua simbol.
///
/// Syarat:
///   • Meja harus terbuka (open = true).
///   • Player belum memiliki bet pending di ronde ini.
///   • Meja belum penuh (players < max_players).
///   • Setiap bet per simbol harus ≥ min_bet.
///   • Semua symbol ID harus dalam rentang [0, 5].
public fun place_bets_at_table(
    table: &mut GameTable,
    symbols: vector<u8>,
    payment: Coin<HACKATHON>,
    ctx: &mut TxContext,
) {
    assert!(table.open, E_TABLE_CLOSED);

    let player = ctx.sender();
    assert!(!table.pending_bets.contains(player), E_ALREADY_BET);
    assert!(table.players.length() < (table.max_players as u64), E_TABLE_FULL);

    let n = symbols.length();
    assert!(n > 0 && n <= 6, E_INVALID_BET);

    let total      = payment.value();
    let bet_amount = total / n;  // pembulatan ke bawah; sisa masuk collateral banker
    assert!(bet_amount >= table.min_bet, E_INVALID_BET);

    // Validasi setiap simbol
    let mut i = 0;
    while (i < n) {
        assert!(symbols[i] < SYMBOL_COUNT, E_INVALID_SYMBOL);
        i = i + 1;
    };

    // Bangun vektor bet per simbol
    let mut bets: vector<Bet> = vector[];
    let mut i = 0;
    while (i < n) {
        bets.push_back(Bet { symbol_id: symbols[i], amount: bet_amount });
        i = i + 1;
    };

    let total_bet = bet_amount * n;
    table.collateral.join(payment.into_balance());
    table.players.push_back(player);
    table.pending_bets.add(player, bets);

    event::emit(BetsPlacedAtTable {
        table_id: object::id(table),
        player,
        total_bet,
    });
}

// ============================================================================
// Public Functions — Banker (resolusi ronde)
// ============================================================================

/// Kocok 3 dadu dan selesaikan semua bet yang tertunda.
/// Hanya banker pemilik meja yang boleh memanggil ini.
///
/// `random_seed` — entropi opsional dari pemanggil (misal nonce frontend).
///   Digabung dengan sumber on-chain agar tidak ada satu pihak yang
///   bisa mengontrol hasil sendirian.
///
/// Setelah roll selesai, pending_bets dan players dikosongkan
/// sehingga ronde berikutnya bisa dimulai.
public fun roll_dice_at_table(
    table: &mut GameTable,
    random_seed: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(table.open, E_TABLE_CLOSED);
    assert!(ctx.sender() == table.banker, E_NOT_BANKER);

    // ── Pseudo-RNG: keccak256(fresh_address ‖ epoch ‖ random_seed) ───────────
    let mut seed = bcs::to_bytes(&ctx.fresh_object_address());
    seed.append(bcs::to_bytes(&ctx.epoch()));
    seed.append(random_seed);
    let h    = hash::keccak256(&seed);
    let dice = vector[h[0] % 6, h[1] % 6, h[2] % 6];

    // ── Hitung dan transfer payout tiap player ────────────────────────────────
    let player_count = table.players.length();
    let mut i = 0;
    while (i < player_count) {
        let player = table.players[i];
        let bets   = table.pending_bets.remove(player);
        let payout = calculate_payout(&bets, &dice);
        // bets di-drop di sini

        if (payout > 0) {
            // Bayar sebanyak yang tersedia jika collateral kurang
            let available     = table.collateral.value();
            let actual_payout = if (available >= payout) { payout } else { available };
            if (actual_payout > 0) {
                let winnings = table.collateral.split(actual_payout);
                transfer::public_transfer(coin::from_balance(winnings, ctx), player);
            };
        };

        i = i + 1;
    };

    // ── Kosongkan daftar player untuk ronde berikutnya ────────────────────────
    while (!table.players.is_empty()) {
        table.players.pop_back();
    };

    event::emit(DiceRolledAtTable {
        table_id: object::id(table),
        dice,
        player_count,
    });
}

// ============================================================================
// View Functions
// ============================================================================

public fun table_collateral(t: &GameTable): u64   { t.collateral.value() }
public fun table_is_open(t: &GameTable): bool     { t.open }
public fun table_banker(t: &GameTable): address   { t.banker }
public fun table_min_bet(t: &GameTable): u64      { t.min_bet }
public fun table_max_players(t: &GameTable): u8   { t.max_players }
public fun table_player_count(t: &GameTable): u64 { t.players.length() }
public fun table_name(t: &GameTable): String      { t.name }

public fun registry_table_count(r: &TableRegistry): u64        { r.tables.length() }
public fun registry_has_table(r: &TableRegistry, id: ID): bool { r.tables.contains(id) }

// ============================================================================
// Private Helpers
// ============================================================================

/// Hitung total payout dari sekumpulan bet terhadap hasil dadu.
/// Payout per bet: 0 cocok → 0  |  n cocok → (n+1) × amount
fun calculate_payout(bets: &vector<Bet>, dice: &vector<u8>): u64 {
    let mut total = 0u64;
    let mut i = 0;
    while (i < bets.length()) {
        let bet = bets[i]; // copy (Bet has copy)
        let mut matches = 0u64;
        let mut j = 0;
        while (j < 3) {
            if (dice[j] == bet.symbol_id) { matches = matches + 1; };
            j = j + 1;
        };
        if (matches > 0) {
            total = total + (matches + 1) * bet.amount;
        };
        i = i + 1;
    };
    total
}

/// Jumlahkan semua amount dalam sebuah vektor bet (untuk kalkulasi refund).
fun sum_bet_amounts(bets: &vector<Bet>): u64 {
    let mut total = 0u64;
    let mut i = 0;
    while (i < bets.length()) {
        total = total + bets[i].amount;
        i = i + 1;
    };
    total
}

// ============================================================================
// Test Helpers
// ============================================================================

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

/// Expose error constants untuk #[expected_failure] di test.
#[test_only] public fun e_insufficient_collateral(): u64 { E_INSUFFICIENT_COLLATERAL }
#[test_only] public fun e_table_closed(): u64            { E_TABLE_CLOSED }
#[test_only] public fun e_not_banker(): u64              { E_NOT_BANKER }
#[test_only] public fun e_already_bet(): u64             { E_ALREADY_BET }
#[test_only] public fun e_table_full(): u64              { E_TABLE_FULL }
#[test_only] public fun e_invalid_symbol(): u64          { E_INVALID_SYMBOL }
#[test_only] public fun e_invalid_bet(): u64             { E_INVALID_BET }
