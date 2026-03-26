/**
 * fund-house.ts — Isi treasury GameState dengan HACKATHON token.
 *
 * Prasyarat:
 *   - deploy.ts sudah dijalankan → deployments/testnet.json ada.
 *   - Deployer memiliki cukup HACKATHON di wallet.
 *
 * Jalankan:
 *   DEPLOYER_PRIVATE_KEY=suiprivkey1... FUND_AMOUNT_HKT=1000 npx tsx scripts/fund-house.ts
 *
 * FUND_AMOUNT_HKT default: 1000 HKT
 */

import { SuiClient } from '@onelabs/sui/client';
import { Ed25519Keypair } from '@onelabs/sui/keypairs/ed25519';
import { Transaction } from '@onelabs/sui/transactions';
import { decodeSuiPrivateKey } from '@onelabs/sui/cryptography';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);
const ROOT       = path.resolve(__dirname, '..');
const JSON_PATH  = path.join(ROOT, 'deployments', 'testnet.json');

// ---------------------------------------------------------------------------
// Helper: parse private key
// ---------------------------------------------------------------------------

function loadKeypair(): Ed25519Keypair {
  const raw = process.env.DEPLOYER_PRIVATE_KEY;
  if (!raw) {
    throw new Error(
      'Environment variable DEPLOYER_PRIVATE_KEY tidak diset.\n' +
      'Contoh: DEPLOYER_PRIVATE_KEY=suiprivkey1... npx tsx scripts/fund-house.ts'
    );
  }
  if (raw.startsWith('suiprivkey1')) {
    const { secretKey } = decodeSuiPrivateKey(raw);
    return Ed25519Keypair.fromSecretKey(secretKey);
  }
  const bytes = Buffer.from(raw.replace(/^0x/, ''), 'hex');
  return Ed25519Keypair.fromSecretKey(bytes.slice(0, 32));
}

// ---------------------------------------------------------------------------
// Helper: pilih coin terbaik (nilai terbesar) dan split jika perlu
// ---------------------------------------------------------------------------

async function splitCoin(
  client: SuiClient,
  tx: Transaction,
  owner: string,
  coinType: string,
  amount: bigint,
): Promise<ReturnType<typeof tx.splitCoins>[0]> {
  const coins = await client.getCoins({ owner, coinType });

  if (coins.data.length === 0) {
    throw new Error(
      `Tidak ada coin ${coinType} di wallet ${owner}.\n` +
      'Pastikan deployer sudah menerima HACKATHON token dari faucet testnet.'
    );
  }

  // Urutkan: nilai terbesar dulu
  const sorted = coins.data.sort(
    (a, b) => Number(BigInt(b.balance) - BigInt(a.balance))
  );
  const largest = sorted[0];

  if (BigInt(largest.balance) < amount) {
    // Jika tidak ada satu coin yang cukup, coba merge semua coin terlebih dahulu
    const totalBalance = coins.data.reduce(
      (sum, c) => sum + BigInt(c.balance), 0n
    );
    if (totalBalance < amount) {
      throw new Error(
        `Total HACKATHON tidak cukup.\n` +
        `  Dibutuhkan : ${amount / 1_000_000_000n} HKT\n` +
        `  Tersedia   : ${totalBalance / 1_000_000_000n} HKT`
      );
    }

    // Merge semua ke coin pertama, lalu split
    const primaryCoin = tx.object(largest.coinObjectId);
    if (coins.data.length > 1) {
      tx.mergeCoins(
        primaryCoin,
        coins.data.slice(1).map((c) => tx.object(c.coinObjectId))
      );
    }
    const [split] = tx.splitCoins(primaryCoin, [tx.pure.u64(amount)]);
    return split;
  }

  const [split] = tx.splitCoins(
    tx.object(largest.coinObjectId),
    [tx.pure.u64(amount)]
  );
  return split;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  // ── Baca deployment config ─────────────────────────────────────────────────
  if (!fs.existsSync(JSON_PATH)) {
    throw new Error(
      `deployments/testnet.json tidak ditemukan.\n` +
      `Jalankan 'npx tsx scripts/deploy.ts' terlebih dahulu.`
    );
  }

  const deployment = JSON.parse(fs.readFileSync(JSON_PATH, 'utf-8')) as {
    packageId: string;
    hackathonType: string;
    rpc: string;
    objects: {
      gameAdmin: string;
      gameState: string;
    };
  };

  const { packageId, hackathonType, rpc, objects } = deployment;
  console.log(`📋  Package ID  : ${packageId}`);
  console.log(`   GameAdmin   : ${objects.gameAdmin}`);
  console.log(`   GameState   : ${objects.gameState}`);

  // ── Setup ──────────────────────────────────────────────────────────────────
  const keypair = loadKeypair();
  const owner   = keypair.getPublicKey().toSuiAddress();
  const client  = new SuiClient({ url: rpc });

  const FUND_AMOUNT_HKT = BigInt(process.env.FUND_AMOUNT_HKT ?? '1000');
  const FUND_AMOUNT_MIST = FUND_AMOUNT_HKT * 1_000_000_000n;

  console.log(`\n🔑  Deployer    : ${owner}`);
  console.log(`💰  Jumlah fund : ${FUND_AMOUNT_HKT} HKT (${FUND_AMOUNT_MIST} MIST)`);

  // ── Cek saldo HACKATHON ────────────────────────────────────────────────────
  const hktBalance = await client.getBalance({ owner, coinType: hackathonType });
  console.log(`   HACKATHON   : ${BigInt(hktBalance.totalBalance) / 1_000_000_000n} HKT tersedia`);

  // ── Bangun transaksi ───────────────────────────────────────────────────────
  const tx = new Transaction();

  const fundCoin = await splitCoin(client, tx, owner, hackathonType, FUND_AMOUNT_MIST);

  tx.moveCall({
    target: `${packageId}::kodok_kodok::fund_house`,
    arguments: [
      tx.object(objects.gameAdmin),  // &GameAdmin
      tx.object(objects.gameState),  // &mut GameState
      fundCoin,                      // Coin<HACKATHON>
    ],
  });

  // ── Eksekusi (dengan retry) ─────────────────────────────────────────────
  console.log('\n🚀  Mengirim transaksi fund_house...');

  let result;
  try {
    result = await client.signAndExecuteTransaction({
      signer: keypair,
      transaction: tx,
      options: { showEffects: true },
    });
  } catch {
    console.log('   Fetch failed, retrying in 2s...');
    await new Promise((r) => setTimeout(r, 2_000));
    result = await client.signAndExecuteTransaction({
      signer: keypair,
      transaction: tx,
      options: { showEffects: true },
    });
  }

  await client.waitForTransaction({ digest: result.digest });

  if (result.effects?.status?.status !== 'success') {
    throw new Error(
      `Transaksi gagal: ${JSON.stringify(result.effects?.status, null, 2)}`
    );
  }

  console.log(`✅  fund_house berhasil!`);
  console.log(`   Tx digest: ${result.digest}`);

  // ── Verifikasi saldo house ─────────────────────────────────────────────────
  const gameStateObj = await client.getObject({
    id: objects.gameState,
    options: { showContent: true },
  });

  const content = gameStateObj.data?.content;
  if (content && 'fields' in content) {
    const fields = content.fields as Record<string, unknown>;
    // house_balance tersimpan sebagai Balance<HACKATHON> → field "value"
    const houseBalance = fields.house_balance as { fields: { value: string } } | undefined;
    if (houseBalance?.fields?.value) {
      const balanceMist = BigInt(houseBalance.fields.value);
      console.log(`\n🏦  House treasury: ${balanceMist / 1_000_000_000n} HKT`);
    }
  }

  console.log('\n🎉  Selesai! Game siap dimainkan.');
}

main().catch((err) => {
  console.error('\n❌  Error:', err.message ?? err);
  process.exit(1);
});
