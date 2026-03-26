import { SuiClient } from '@onelabs/sui/client';
import { Ed25519Keypair } from '@onelabs/sui/keypairs/ed25519';
import { Transaction } from '@onelabs/sui/transactions';
import { decodeSuiPrivateKey } from '@onelabs/sui/cryptography';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __filename   = fileURLToPath(import.meta.url);
const __dirname    = path.dirname(__filename);
const SC_ROOT      = path.resolve(__dirname, '..');
const PROJECT_ROOT = path.resolve(SC_ROOT, '..');
const JSON_PATH    = path.join(SC_ROOT, 'deployments', 'testnet.json');
const ENV_PATH     = path.join(PROJECT_ROOT, 'frontend', '.env.local');

function loadKeypair(): Ed25519Keypair {
  const raw = process.env.DEPLOYER_PRIVATE_KEY;
  if (!raw) throw new Error('DEPLOYER_PRIVATE_KEY tidak diset.');
  if (raw.startsWith('suiprivkey1')) {
    const { secretKey } = decodeSuiPrivateKey(raw);
    return Ed25519Keypair.fromSecretKey(secretKey);
  }
  const bytes = Buffer.from(raw.replace(/^0x/, ''), 'hex');
  return Ed25519Keypair.fromSecretKey(bytes.slice(0, 32));
}

async function main() {
  if (!fs.existsSync(JSON_PATH)) {
    throw new Error('deployments/testnet.json tidak ditemukan. Jalankan deploy.ts dulu.');
  }

  const deployment = JSON.parse(fs.readFileSync(JSON_PATH, 'utf-8')) as {
    packageId: string;
    rpc: string;
    objects: { tournamentAdmin: string };
  };

  const { packageId, rpc, objects } = deployment;

  const DURATION_DAYS = Number(process.env.DURATION_DAYS ?? '7');
  const DURATION_MS   = BigInt(DURATION_DAYS * 24 * 60 * 60 * 1000);

  const keypair = loadKeypair();
  const owner   = keypair.getPublicKey().toSuiAddress();
  const client  = new SuiClient({ url: rpc });

  console.log(`Package         : ${packageId}`);
  console.log(`TournamentAdmin : ${objects.tournamentAdmin}`);
  console.log(`Deployer        : ${owner}`);
  console.log(`Duration        : ${DURATION_DAYS} hari (${DURATION_MS} ms)\n`);

  const tx = new Transaction();
  tx.moveCall({
    target: `${packageId}::tournament::create_tournament`,
    arguments: [
      tx.object(objects.tournamentAdmin),
      tx.pure.u64(DURATION_MS),
    ],
  });

  console.log('Mengirim transaksi create_tournament...');
  const result = await client.signAndExecuteTransaction({
    signer: keypair,
    transaction: tx,
    options: { showObjectChanges: true, showEffects: true },
  });

  await client.waitForTransaction({ digest: result.digest });

  if (result.effects?.status?.status !== 'success') {
    throw new Error(`Transaksi gagal: ${JSON.stringify(result.effects?.status)}`);
  }

  const created = result.objectChanges?.find(
    (c) => c.type === 'created' && (c as { objectType: string }).objectType?.includes('::tournament::Tournament'),
  );
  const tournamentId = (created as { objectId: string })?.objectId;

  if (!tournamentId) throw new Error('Tidak bisa menemukan Tournament object ID dari hasil transaksi.');

  console.log(`\nTournament ID   : ${tournamentId}`);
  console.log(`Tx digest       : ${result.digest}`);

  // Update deployments/testnet.json
  const updated = JSON.parse(fs.readFileSync(JSON_PATH, 'utf-8'));
  updated.objects.tournament = tournamentId;
  fs.writeFileSync(JSON_PATH, JSON.stringify(updated, null, 2));
  console.log(`\ndeployments/testnet.json diperbarui.`);

  // Update frontend/.env.local
  if (fs.existsSync(ENV_PATH)) {
    let env = fs.readFileSync(ENV_PATH, 'utf-8');
    if (env.includes('NEXT_PUBLIC_TOURNAMENT_ID=')) {
      env = env.replace(/NEXT_PUBLIC_TOURNAMENT_ID=.*/, `NEXT_PUBLIC_TOURNAMENT_ID=${tournamentId}`);
    } else {
      env += `\nNEXT_PUBLIC_TOURNAMENT_ID=${tournamentId}`;
    }
    fs.writeFileSync(ENV_PATH, env);
    console.log(`frontend/.env.local diperbarui.`);
  }

  console.log('\nTournament berhasil dibuat dan siap digunakan.');
}

main().catch((err) => {
  console.error('Error:', err.message ?? err);
  process.exit(1);
});
