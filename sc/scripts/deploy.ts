/**
 * deploy.ts — Publish kontrak kodok_kodok ke OneChain testnet.
 *
 * Langkah yang dijalankan:
 *   1. sui move build (non-test, dari contracts/kodok_kodok)
 *   2. Baca bytecode modul dari build/kodok_kodok/bytecode_modules/
 *   3. Publish via signAndExecuteTransaction
 *   4. Ekstrak Package ID + semua Object ID dari objectChanges
 *   5. Simpan ke deployments/testnet.json
 *   6. Generate frontend/src/lib/deployment.ts
 *
 * Jalankan:
 *   DEPLOYER_PRIVATE_KEY=suiprivkey1... npx tsx scripts/deploy.ts
 */

import { SuiClient } from '@onelabs/sui/client';
import { Ed25519Keypair } from '@onelabs/sui/keypairs/ed25519';
import { Transaction } from '@onelabs/sui/transactions';
import { decodeSuiPrivateKey } from '@onelabs/sui/cryptography';
import { execSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

// ---------------------------------------------------------------------------
// Konstanta
// ---------------------------------------------------------------------------

const RPC = 'https://rpc-testnet.onelabs.cc:443';
const HACKATHON_PKG = '0x8b76fc2a2317d45118770cefed7e57171a08c477ed16283616b15f099391f120';
const HACKATHON_TYPE = `${HACKATHON_PKG}::hackathon::HACKATHON`;

/**
 * Dependency package IDs yang harus disertakan saat publish.
 * Urutan tidak penting; Sui node akan memvalidasinya.
 */
const FRAMEWORK_DEPS = [
  '0x0000000000000000000000000000000000000000000000000000000000000001', // MoveStdlib
  '0x0000000000000000000000000000000000000000000000000000000000000002', // Sui
  '0x0000000000000000000000000000000000000000000000000000000000000003', // SuiSystem
  '0x000000000000000000000000000000000000000000000000000000000000000b', // Bridge
  HACKATHON_PKG,
];

/** Modul yang di-publish (urutan tidak sensitif); tidak termasuk modul _tests. */
const PUBLISH_MODULES = ['kodok_kodok', 'tournament', 'social_table', 'prediction'];

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

const __filename   = fileURLToPath(import.meta.url);
const __dirname    = path.dirname(__filename);
const SC_ROOT      = path.resolve(__dirname, '..');
const PROJECT_ROOT = path.resolve(SC_ROOT, '..');
const CONTRACT     = path.join(SC_ROOT, 'kodok_kodok');
const BUILD_DIR    = path.join(CONTRACT, 'build', 'kodok_kodok', 'bytecode_modules');
const DEPLOY_DIR   = path.join(SC_ROOT, 'deployments');
const FRONTEND_LIB = path.join(PROJECT_ROOT, 'frontend', 'src', 'lib');

// ---------------------------------------------------------------------------
// Helper: parse private key (bech32 suiprivkey1... atau raw hex)
// ---------------------------------------------------------------------------

function loadKeypair(): Ed25519Keypair {
  const raw = process.env.DEPLOYER_PRIVATE_KEY;
  if (!raw) {
    throw new Error(
      'Environment variable DEPLOYER_PRIVATE_KEY tidak diset.\n' +
      'Contoh: DEPLOYER_PRIVATE_KEY=suiprivkey1... npx tsx scripts/deploy.ts'
    );
  }

  if (raw.startsWith('suiprivkey1')) {
    // Bech32 encoded — format export dari `sui keytool export`
    const { secretKey } = decodeSuiPrivateKey(raw);
    return Ed25519Keypair.fromSecretKey(secretKey);
  }

  // Fallback: anggap raw hex 32 atau 64 byte
  const bytes = Buffer.from(raw.replace(/^0x/, ''), 'hex');
  return Ed25519Keypair.fromSecretKey(bytes.subarray(0, 32));
}

// ---------------------------------------------------------------------------
// Helper: cari object dari objectChanges berdasarkan akhiran tipe
// ---------------------------------------------------------------------------

type ObjChange = {
  type: string;
  objectType?: string;
  objectId?: string;
  packageId?: string;
};

function findCreatedId(changes: ObjChange[], typeSuffix: string): string {
  const found = changes.find(
    (c) => c.type === 'created' && c.objectType?.endsWith(typeSuffix)
  );
  if (!found?.objectId) {
    throw new Error(`Object '${typeSuffix}' tidak ditemukan dalam objectChanges.`);
  }
  return found.objectId;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  // ── 1. Build (production, tanpa flag --test) ───────────────────────────────
  console.log('🔨  Building Move contracts...');
  execSync('sui move build --skip-fetch-latest-git-deps', {
    cwd: CONTRACT,
    stdio: 'inherit',
  });

  // ── 2. Baca bytecode modul ─────────────────────────────────────────────────
  console.log('\n📦  Reading bytecode modules...');
  const modules = PUBLISH_MODULES.map((name) => {
    const mvPath = path.join(BUILD_DIR, `${name}.mv`);
    if (!fs.existsSync(mvPath)) {
      throw new Error(`Bytecode tidak ditemukan: ${mvPath}\nJalankan 'sui move build' terlebih dahulu.`);
    }
    return Array.from(fs.readFileSync(mvPath)) as number[];
  });
  console.log(`   Modules: ${PUBLISH_MODULES.join(', ')}`);

  // ── 3. Setup client & keypair ──────────────────────────────────────────────
  const keypair = loadKeypair();
  const deployer = keypair.getPublicKey().toSuiAddress();
  const client   = new SuiClient({ url: RPC });
  console.log(`\n🔑  Deployer: ${deployer}`);

  // Cek saldo SUI untuk gas
  const balance = await client.getBalance({ owner: deployer });
  console.log(`   SUI balance: ${BigInt(balance.totalBalance) / 1_000_000_000n} SUI`);
  if (BigInt(balance.totalBalance) < 100_000_000n) {
    throw new Error('Saldo SUI tidak cukup untuk gas. Minimal ~0.1 SUI diperlukan.');
  }

  // ── 4. Publish ─────────────────────────────────────────────────────────────
  console.log('\n🚀  Publishing contract...');
  const tx = new Transaction();
  const [upgradeCap] = tx.publish({
    modules,
    dependencies: FRAMEWORK_DEPS,
  });
  // UpgradeCap harus di-transfer — tidak bisa dibiarkan (Sui akan reject)
  tx.transferObjects([upgradeCap], deployer);

  const result = await client.signAndExecuteTransaction({
    signer: keypair,
    transaction: tx,
    options: {
      showObjectChanges: true,
      showEffects: true,
    },
  });

  console.log(`   Tx digest: ${result.digest}`);

  if (result.effects?.status?.status !== 'success') {
    throw new Error(
      `Transaksi gagal: ${JSON.stringify(result.effects?.status, null, 2)}`
    );
  }

  // ── 5. Ekstrak IDs ──────────────────────────────────────────────────────────
  const changes = (result.objectChanges ?? []) as ObjChange[];

  const publishedChange = changes.find((c) => c.type === 'published');
  if (!publishedChange?.packageId) {
    throw new Error('packageId tidak ditemukan dalam objectChanges.');
  }
  const packageId = publishedChange.packageId;

  const objects = {
    gameAdmin:      findCreatedId(changes, '::kodok_kodok::GameAdmin'),
    gameState:      findCreatedId(changes, '::kodok_kodok::GameState'),
    tournamentAdmin: findCreatedId(changes, '::tournament::TournamentAdmin'),
    tableRegistry:  findCreatedId(changes, '::social_table::TableRegistry'),
    predictionAdmin: findCreatedId(changes, '::prediction::PredictionAdmin'),
    upgradeCap:     findCreatedId(changes, '::package::UpgradeCap'),
  };

  // Tunggu finalisasi di background (non-blocking untuk output)
  client.waitForTransaction({ digest: result.digest }).catch(() => {});

  console.log('\n✅  Deploy berhasil!');
  console.log(`   Package ID     : ${packageId}`);
  console.log(`   GameAdmin      : ${objects.gameAdmin}`);
  console.log(`   GameState      : ${objects.gameState}`);
  console.log(`   TournamentAdmin: ${objects.tournamentAdmin}`);
  console.log(`   TableRegistry  : ${objects.tableRegistry}`);
  console.log(`   PredictionAdmin: ${objects.predictionAdmin}`);
  console.log(`   UpgradeCap     : ${objects.upgradeCap}`);

  // ── 6. Simpan deployments/testnet.json ────────────────────────────────────
  fs.mkdirSync(DEPLOY_DIR, { recursive: true });

  const deploymentData = {
    network: 'testnet',
    rpc: RPC,
    packageId,
    hackathonType: HACKATHON_TYPE,
    deployedAt: new Date().toISOString(),
    deployer,
    txDigest: result.digest,
    objects,
  };

  const jsonPath = path.join(DEPLOY_DIR, 'testnet.json');
  fs.writeFileSync(jsonPath, JSON.stringify(deploymentData, null, 2));
  console.log(`\n💾  Deployment data → ${path.relative(SC_ROOT, jsonPath)}`);

  // ── 7. Generate frontend/src/lib/deployment.ts ────────────────────────────
  fs.mkdirSync(FRONTEND_LIB, { recursive: true });

  const tsContent = `// AUTO-GENERATED oleh scripts/deploy.ts — jangan edit manual.
// Deploy: ${deploymentData.deployedAt}
// Tx: ${result.digest}

export const PACKAGE_ID = '${packageId}' as const;

export const HACKATHON_TYPE = '${HACKATHON_TYPE}' as const;

export const OBJECTS = {
  gameAdmin:       '${objects.gameAdmin}',
  gameState:       '${objects.gameState}',
  tournamentAdmin: '${objects.tournamentAdmin}',
  tableRegistry:   '${objects.tableRegistry}',
  predictionAdmin: '${objects.predictionAdmin}',
  upgradeCap:      '${objects.upgradeCap}',
} as const;

/** RPC endpoint OneChain testnet */
export const RPC_URL = '${RPC}' as const;
`;

  const tsPath = path.join(FRONTEND_LIB, 'deployment.ts');
  fs.writeFileSync(tsPath, tsContent);
  console.log(`📄  deployment.ts  → ${path.relative(PROJECT_ROOT, tsPath)}`);
  console.log('\n🎉  Selesai! Jalankan fund-house.ts untuk mengisi treasury game.');
}

main().catch((err) => {
  console.error('\n❌  Error:', err.message ?? err);
  process.exit(1);
});
