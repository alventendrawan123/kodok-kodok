/**
 * fund-player.ts — Generate a fresh player wallet and fund it with HKT + OCT.
 *
 * Usage:
 *   DEPLOYER_PRIVATE_KEY=suiprivkey1... npx tsx scripts/fund-player.ts
 *   DEPLOYER_PRIVATE_KEY=0x1e6abf86... npx tsx scripts/fund-player.ts
 *
 * Optional env vars:
 *   HKT_AMOUNT   — HKT to send (default: 100)
 *   OCT_AMOUNT   — OCT gas to send in MIST (default: 500000000 = 0.5 OCT)
 */

import { SuiClient } from '@onelabs/sui/client';
import { Ed25519Keypair } from '@onelabs/sui/keypairs/ed25519';
import { Transaction } from '@onelabs/sui/transactions';
import { decodeSuiPrivateKey } from '@onelabs/sui/cryptography';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);
const ROOT       = path.resolve(__dirname, '..');
const JSON_PATH  = path.join(ROOT, 'deployments', 'testnet.json');

function loadDeployerKeypair(): Ed25519Keypair {
  const raw = process.env.DEPLOYER_PRIVATE_KEY;
  if (!raw) {
    throw new Error(
      'DEPLOYER_PRIVATE_KEY is not set.\n' +
      'Example: DEPLOYER_PRIVATE_KEY=suiprivkey1... npx tsx scripts/fund-player.ts',
    );
  }
  if (raw.startsWith('suiprivkey1')) {
    const { secretKey } = decodeSuiPrivateKey(raw);
    return Ed25519Keypair.fromSecretKey(secretKey);
  }
  const bytes = Buffer.from(raw.replace(/^0x/, ''), 'hex');
  return Ed25519Keypair.fromSecretKey(bytes.slice(0, 32));
}

async function splitHkt(
  client: SuiClient,
  tx: Transaction,
  owner: string,
  coinType: string,
  amount: bigint,
) {
  const coins = await client.getCoins({ owner, coinType });
  if (!coins.data.length) {
    throw new Error(`No ${coinType} coins found in deployer wallet.`);
  }

  const sorted  = coins.data.sort((a, b) => Number(BigInt(b.balance) - BigInt(a.balance)));
  const largest = sorted[0];

  const total = coins.data.reduce((s, c) => s + BigInt(c.balance), 0n);
  if (total < amount) {
    throw new Error(
      `Insufficient HKT.\n  Required: ${amount / 1_000_000_000n} HKT\n  Available: ${total / 1_000_000_000n} HKT`,
    );
  }

  const primary = tx.object(largest.coinObjectId);
  if (coins.data.length > 1 && BigInt(largest.balance) < amount) {
    tx.mergeCoins(primary, coins.data.slice(1).map((c) => tx.object(c.coinObjectId)));
  }

  const [split] = tx.splitCoins(primary, [tx.pure.u64(amount)]);
  return split;
}

async function main() {
  if (!fs.existsSync(JSON_PATH)) {
    throw new Error(`deployments/testnet.json not found. Run deploy.ts first.`);
  }

  const deployment = JSON.parse(fs.readFileSync(JSON_PATH, 'utf-8')) as {
    hackathonType: string;
    rpc: string;
  };

  const { hackathonType, rpc } = deployment;

  const HKT_AMOUNT  = BigInt(process.env.HKT_AMOUNT ?? '100');
  const OCT_AMOUNT  = BigInt(process.env.OCT_AMOUNT ?? '500000000');
  const HKT_MIST    = HKT_AMOUNT * 1_000_000_000n;

  const playerKeypair     = Ed25519Keypair.generate();
  const playerPrivKeyBech = playerKeypair.getSecretKey();
  const { secretKey }     = decodeSuiPrivateKey(playerPrivKeyBech);
  const playerPrivKeyHex  = '0x' + Buffer.from(secretKey).toString('hex');
  const playerAddress     = playerKeypair.getPublicKey().toSuiAddress();

  console.log('\n========================================');
  console.log('  NEW PLAYER WALLET');
  console.log('========================================');
  console.log(`  Address     : ${playerAddress}`);
  console.log(`  Private Key : ${playerPrivKeyHex}`);
  console.log(`  (Bech32)    : ${playerPrivKeyBech}`);
  console.log('========================================\n');
  console.log('  Import the private key (hex) into OneWallet to play as this player.\n');

  const deployerKeypair = loadDeployerKeypair();
  const deployerAddress = deployerKeypair.getPublicKey().toSuiAddress();
  const client          = new SuiClient({ url: rpc });

  console.log(`  Deployer : ${deployerAddress}`);
  console.log(`  Sending  : ${HKT_AMOUNT} HKT + ${Number(OCT_AMOUNT) / 1e9} OCT → ${playerAddress}\n`);

  const tx      = new Transaction();
  const hktCoin = await splitHkt(client, tx, deployerAddress, hackathonType, HKT_MIST);

  tx.transferObjects([hktCoin], tx.pure.address(playerAddress));

  const [octCoin] = tx.splitCoins(tx.gas, [tx.pure.u64(OCT_AMOUNT)]);
  tx.transferObjects([octCoin], tx.pure.address(playerAddress));

  console.log('  Submitting transaction...');
  const result = await client.signAndExecuteTransaction({
    signer: deployerKeypair,
    transaction: tx,
    options: { showEffects: true },
  });

  await client.waitForTransaction({ digest: result.digest });

  if (result.effects?.status?.status !== 'success') {
    throw new Error(`Transaction failed: ${JSON.stringify(result.effects?.status)}`);
  }

  console.log(`  Tx digest : ${result.digest}`);
  console.log('\n========================================');
  console.log('  SUMMARY — import this into OneWallet');
  console.log('========================================');
  console.log(`  Private Key (hex) : ${playerPrivKeyHex}`);
  console.log(`  Address           : ${playerAddress}`);
  console.log(`  Funded with       : ${HKT_AMOUNT} HKT + ${Number(OCT_AMOUNT) / 1e9} OCT`);
  console.log('========================================\n');
}

main().catch((err) => {
  console.error('\nError:', err.message ?? err);
  process.exit(1);
});
