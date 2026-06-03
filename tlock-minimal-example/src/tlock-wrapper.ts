// Browser-bundle entry point for the CIP-179 timelocked-ballots demo.
//
// Exposes three async functions intended to be registered as elm-concurrent-task
// tasks ("tlock:encrypt" / "tlock:fetchRound" / "tlock:decrypt"). Data crosses
// the concurrent-task JSON channel as strings: hex for plaintext/ciphertext, and
// a JSON-stringified Drand beacon for the round signature.
//
// Round fetching and decryption are DECOUPLED. Every ballot of a survey is
// locked to the same Drand round, and a published round's signature is
// immutable, so the network beacon is fetched once (`fetchRound`) and reused to
// decrypt every ballot locally (`decrypt`) with no further network I/O.
//
// Crypto is delegated to the @mpizenberg/tlock-js fork's high-level
// timelockEncrypt / timelockDecrypt (Drand quicknet, scheme
// bls-unchained-g1-rfc9380): a random 32-byte file key is IBE-encrypted to the
// target round and the payload is ChaCha20-STREAM-encrypted under that key. The
// only customization here is stripping the PEM "age armor" so the stored blob is
// the raw binary age payload.
//
// quicknet constants (owned by mainnetClient() in the fork, repeated here for
// documentation only):
//   chainHash   = 52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971
//   publicKey   = 83cf0f...ece45a (G2)
//   genesisTime = 1692803367 (unix s)   period = 3 s
//   scheme      = bls-unchained-g1-rfc9380
//   beacon      = https://api.drand.sh/<chainHash>/public/<round>

import {
  timelockEncrypt,
  timelockDecrypt,
  mainnetClient,
  Buffer,
} from "@mpizenberg/tlock-js/src/index";
import { decodeArmor } from "@mpizenberg/tlock-js/src/age/armor";
import {
  fetchBeacon,
  type ChainClient,
  type HttpChainClient,
  type RandomnessBeacon,
} from "@mpizenberg/tlock-js/src/drand/drand-client";

// quicknet client; verifies fetched chain info against the pinned hash + pubkey.
let cachedClient: HttpChainClient | null = null;
function client(): HttpChainClient {
  if (cachedClient === null) {
    cachedClient = mainnetClient();
  }
  return cachedClient;
}

// An offline ChainClient that serves an already-fetched beacon for any requested
// round and delegates chain info to the real (cached) client. Lets
// timelockDecrypt run with zero network I/O, while the beacon is still verified
// locally against the pinned chain info inside timelockDecrypt.
function beaconClient(beacon: RandomnessBeacon): ChainClient {
  const real = client();
  return {
    options: real.options,
    chain: () => real.chain(),
    get: async () => beacon,
    latest: async () => beacon,
  };
}

export interface EncryptArgs {
  round: number;
  plaintextHex: string;
}
export interface EncryptResult {
  ciphertextHex: string;
}
export interface FetchRoundArgs {
  round: number;
}
export interface FetchRoundResult {
  beaconJson: string;
}
export interface DecryptArgs {
  ciphertextHex: string;
  beaconJson: string;
}
export interface DecryptResult {
  plaintextHex: string;
}

// Encrypt to round R. Local crypto only (the client fetches chain info once to
// learn the scheme/pubkey). Returns the armor-stripped binary age payload.
export async function encrypt(args: EncryptArgs): Promise<EncryptResult> {
  const payload = Buffer.from(args.plaintextHex, "hex");
  const armored = await timelockEncrypt(args.round, payload, client());
  // decodeArmor -> binary string (one char per byte); re-encode as hex.
  const ageBinary = decodeArmor(armored);
  const ciphertextHex = Buffer.from(ageBinary, "binary").toString("hex");
  return { ciphertextHex };
}

// Fetch and verify the Drand beacon for round R. This is the ONLY networked step
// of a reveal: call it once per survey, then reuse the result to decrypt every
// ballot. Throws if the round has not yet been published.
export async function fetchRound(
  args: FetchRoundArgs,
): Promise<FetchRoundResult> {
  const beacon = await fetchBeacon(client(), args.round);
  return { beaconJson: JSON.stringify(beacon) };
}

// Decrypt an armor-stripped age payload (hex) using a beacon previously obtained
// from fetchRound. Pure/offline: no network I/O. The beacon is still verified
// locally against the pinned chain info inside timelockDecrypt.
export async function decrypt(args: DecryptArgs): Promise<DecryptResult> {
  const beacon = JSON.parse(args.beaconJson) as RandomnessBeacon;
  const ageBinary = Buffer.from(args.ciphertextHex, "hex").toString("binary");
  const plaintext = await timelockDecrypt(ageBinary, beaconClient(beacon));
  return { plaintextHex: plaintext.toString("hex") };
}
