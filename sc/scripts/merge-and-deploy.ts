import { SuiClient } from '@onelabs/sui/client';
import { Ed25519Keypair } from '@onelabs/sui/keypairs/ed25519';
import { Transaction } from '@onelabs/sui/transactions';
import { decodeSuiPrivateKey } from '@onelabs/sui/cryptography';
import { execSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const RPC            = 'https://rpc-testnet.onelabs.cc:443';
const HACKATHON_PKG  = '0x8b76fc2a2317d45118770cefed7e57171a08c477ed16283616b15f099391f120';
const HACKATHON_TYPE = `${HACKATHON_PKG}::hackathon::HACKATHON`;

const FRAMEWORK_DEPS = [
  '0x0000000000000000000000000000000000000000000000000000000000000001',
  '0x0000000000000000000000000000000000000000000000000000000000000002',
  '0x0000000000000000000000000000000000000000000000000000000000000003',
  '0x000000000000000000000000000000000000000000000000000000000000000b',
  HACKATHON_PKG,
];

const PUBLISH_MODULES = ['kodok_kodok', 'tournament', 'social_table', 'prediction'];

const __filename   = fileURLToPath(import.meta.url);
const __dirname    = path.dirname(__filename);
const SC_ROOT      = path.resolve(__dirname, '..');
const PROJECT_ROOT = path.resolve(SC_ROOT, '..');
const CONTRACT     = path.join(SC_ROOT, 'kodok_kodok');
const BUILD_DIR    = path.join(CONTRACT, 'build', 'kodok_kodok', 'bytecode_modules');
const DEPLOY_DIR   = path.join(SC_ROOT, 'deployments');
const FRONTEND_LIB = path.join(PROJECT_ROOT, 'frontend', 'src', 'lib');

function loadKeypair(): Ed25519Keypair {
  const raw = process.env.DEPLOYER_PRIVATE_KEY;
  if (!raw) {
    throw new Error(
      'DEPLOYER_PRIVATE_KEY not set.\n' +
      'Usage: DEPLOYER_PRIVATE_KEY=suiprivkey1... npx tsx scripts/merge-and-deploy.ts',
    );
  }
  if (raw.startsWith('suiprivkey1')) {
    const { secretKey } = decodeSuiPrivateKey(raw);
    return Ed25519Keypair.fromSecretKey(secretKey);
  }
  const bytes = Buffer.from(raw.replace(/^0x/, ''), 'hex');
  return Ed25519Keypair.fromSecretKey(bytes.subarray(0, 32));
}

type ObjChange = {
  type: string;
  objectType?: string;
  objectId?: string;
  packageId?: string;
};

function findCreatedId(changes: ObjChange[], typeSuffix: string): string {
  const found = changes.find(
    (c) => c.type === 'created' && c.objectType?.endsWith(typeSuffix),
  );
  if (!found?.objectId) {
    throw new Error(`Object '${typeSuffix}' not found in objectChanges.`);
  }
  return found.objectId;
}

type CoinData = { coinObjectId: string; balance: string };

async function getAllCoins(client: SuiClient, owner: string): Promise<CoinData[]> {
  const all: CoinData[] = [];
  let cursor: string | null | undefined = undefined;
  let hasNext = true;

  while (hasNext) {
    const page = await client.getCoins({
      owner,
      coinType: '0x2::oct::OCT',
      cursor: cursor ?? undefined,
    });
    all.push(...page.data);
    hasNext = page.hasNextPage;
    cursor  = page.nextCursor;
  }

  return all;
}

function fixMoveLock() {
  const lockPath = path.join(CONTRACT, 'Move.lock');
  if (!fs.existsSync(lockPath)) return;
  const content = fs.readFileSync(lockPath, 'utf-8');
  const fixed   = content.replace(/\.\.[\\]/g, '../');
  if (fixed !== content) {
    fs.writeFileSync(lockPath, fixed);
    console.log('  Fixed backslash paths in Move.lock');
  }
}

async function main() {
  const keypair  = loadKeypair();
  const deployer = keypair.getPublicKey().toSuiAddress();
  const client   = new SuiClient({ url: RPC });

  console.log(`Deployer: ${deployer}\n`);

  // ── 1. Query all OCT (native gas) coins ──────────────────────────────────
  console.log('Step 1: Querying OCT coins...');
  const coins = await getAllCoins(client, deployer);

  let totalBalance = 0n;
  for (const c of coins) {
    const oct = BigInt(c.balance);
    totalBalance += oct;
    console.log(`  ${c.coinObjectId}  ${(Number(oct) / 1e9).toFixed(4)} OCT`);
  }
  console.log(`  Total: ${coins.length} coins, ${(Number(totalBalance) / 1e9).toFixed(4)} OCT\n`);

  if (coins.length === 0) {
    throw new Error('No OCT coins found.');
  }

  // ── 2. Merge coins if more than 1 ────────────────────────────────────────
  if (coins.length > 1) {
    console.log(`Step 2: Merging ${coins.length} coins into 1...`);

    coins.sort((a, b) => {
      const ba = BigInt(a.balance);
      const bb = BigInt(b.balance);
      return ba > bb ? -1 : ba < bb ? 1 : 0;
    });

    const primary = coins[0].coinObjectId;
    const others  = coins.slice(1);
    const BATCH   = 200;

    for (let i = 0; i < others.length; i += BATCH) {
      const batch = others.slice(i, i + BATCH);
      const tx    = new Transaction();
      tx.mergeCoins(
        tx.object(primary),
        batch.map((c) => tx.object(c.coinObjectId)),
      );

      const mergeResult = await client.signAndExecuteTransaction({
        signer:      keypair,
        transaction: tx,
        options:     { showEffects: true },
      });

      if (mergeResult.effects?.status?.status !== 'success') {
        throw new Error(`Merge failed: ${JSON.stringify(mergeResult.effects?.status)}`);
      }

      await client.waitForTransaction({ digest: mergeResult.digest });
      console.log(`  Batch ${Math.floor(i / BATCH) + 1}: merged ${batch.length} coins (${mergeResult.digest})`);
    }

    console.log('  Waiting 3s for finalization...');
    await new Promise((r) => setTimeout(r, 3_000));

    const postBalance = await client.getBalance({ owner: deployer });
    console.log(`  Post-merge balance: ${(Number(BigInt(postBalance.totalBalance)) / 1e9).toFixed(4)} OCT\n`);
  } else {
    console.log('Step 2: Only 1 coin, no merge needed.\n');
  }

  // ── 3. Build Move contracts ──────────────────────────────────────────────
  console.log('Step 3: Building Move contracts...');
  const lockPath = path.join(CONTRACT, 'Move.lock');
  if (fs.existsSync(lockPath)) {
    fs.unlinkSync(lockPath);
    console.log('  Deleted stale Move.lock');
  }

  execSync('sui move build --skip-fetch-latest-git-deps', {
    cwd:   CONTRACT,
    stdio: 'inherit',
  });
  fixMoveLock();

  // ── 4. Read bytecode modules ─────────────────────────────────────────────
  console.log('\nStep 4: Reading bytecode modules...');
  const modules = PUBLISH_MODULES.map((name) => {
    const mvPath = path.join(BUILD_DIR, `${name}.mv`);
    if (!fs.existsSync(mvPath)) {
      throw new Error(`Bytecode not found: ${mvPath}`);
    }
    return Array.from(fs.readFileSync(mvPath)) as number[];
  });
  console.log(`  Modules: ${PUBLISH_MODULES.join(', ')}\n`);

  // ── 5. Publish ───────────────────────────────────────────────────────────
  console.log('Step 5: Publishing contract...');
  const tx = new Transaction();
  const [upgradeCap] = tx.publish({ modules, dependencies: FRAMEWORK_DEPS });
  tx.transferObjects([upgradeCap], deployer);

  const result = await client.signAndExecuteTransaction({
    signer:      keypair,
    transaction: tx,
    options:     { showObjectChanges: true, showEffects: true },
  });

  console.log(`  Tx digest: ${result.digest}`);

  if (result.effects?.status?.status !== 'success') {
    throw new Error(`Publish failed: ${JSON.stringify(result.effects?.status, null, 2)}`);
  }

  await client.waitForTransaction({ digest: result.digest });

  // ── 6. Extract IDs ───────────────────────────────────────────────────────
  const changes = (result.objectChanges ?? []) as ObjChange[];

  const publishedChange = changes.find((c) => c.type === 'published');
  if (!publishedChange?.packageId) {
    throw new Error('packageId not found in objectChanges.');
  }
  const packageId = publishedChange.packageId;

  const objects = {
    gameAdmin:       findCreatedId(changes, '::kodok_kodok::GameAdmin'),
    gameState:       findCreatedId(changes, '::kodok_kodok::GameState'),
    tournamentAdmin: findCreatedId(changes, '::tournament::TournamentAdmin'),
    tableRegistry:   findCreatedId(changes, '::social_table::TableRegistry'),
    predictionAdmin: findCreatedId(changes, '::prediction::PredictionAdmin'),
    upgradeCap:      findCreatedId(changes, '::package::UpgradeCap'),
  };

  console.log('\n  Deploy successful!');
  console.log(`  Package ID      : ${packageId}`);
  console.log(`  GameAdmin       : ${objects.gameAdmin}`);
  console.log(`  GameState       : ${objects.gameState}`);
  console.log(`  TournamentAdmin : ${objects.tournamentAdmin}`);
  console.log(`  TableRegistry   : ${objects.tableRegistry}`);
  console.log(`  PredictionAdmin : ${objects.predictionAdmin}`);
  console.log(`  UpgradeCap      : ${objects.upgradeCap}`);

  // ── 7. Save deployments/testnet.json ─────────────────────────────────────
  fs.mkdirSync(DEPLOY_DIR, { recursive: true });

  const deploymentData = {
    network:      'testnet',
    rpc:          RPC,
    packageId,
    hackathonType: HACKATHON_TYPE,
    deployedAt:   new Date().toISOString(),
    deployer,
    txDigest:     result.digest,
    objects,
  };

  const jsonPath = path.join(DEPLOY_DIR, 'testnet.json');
  fs.writeFileSync(jsonPath, JSON.stringify(deploymentData, null, 2));
  console.log(`\n  Saved ${path.relative(SC_ROOT, jsonPath)}`);

  // ── 8. Generate frontend/src/lib/deployment.ts ───────────────────────────
  fs.mkdirSync(FRONTEND_LIB, { recursive: true });

  const tsContent = `// AUTO-GENERATED by scripts/merge-and-deploy.ts
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

export const RPC_URL = '${RPC}' as const;
`;

  const tsPath = path.join(FRONTEND_LIB, 'deployment.ts');
  fs.writeFileSync(tsPath, tsContent);
  console.log(`  Saved ${path.relative(PROJECT_ROOT, tsPath)}`);
  console.log('\n  Done! Run fund-house.ts next to fill the game treasury.');
}

main().catch((err) => {
  console.error('\nError:', err.message ?? err);
  process.exit(1);
});
