// Browser-bundle entry point for the CIP-179 timelocked-ballots demo.
//
// Exposes two async functions, encrypt/decrypt, intended to be registered as
// elm-concurrent-task tasks ("tlock:encrypt" / "tlock:decrypt"). All data
// crosses the concurrent-task JSON channel as lowercase hex strings.
//
// Crypto is delegated entirely to the @mpizenberg/tlock-js fork's high-level
// timelockEncrypt / timelockDecrypt (Drand quicknet, scheme
// bls-unchained-g1-rfc9380): a random 32-byte file key is IBE-encrypted to the
// target round and the payload is ChaCha20-STREAM-encrypted under that key.
// The only customization here is stripping the PEM "age armor" so the stored
// blob is the raw binary age payload. The target round and chain hash remain
// embedded in the age tlock stanza, so decrypt needs no out-of-band round.
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
  type HttpChainClient,
} from "@mpizenberg/tlock-js/src/index";
import { decodeArmor } from "@mpizenberg/tlock-js/src/age/armor";

// quicknet client; verifies fetched chain info against the pinned hash + pubkey.
let cachedClient: HttpChainClient | null = null;
function client(): HttpChainClient {
  if (cachedClient === null) {
    cachedClient = mainnetClient();
  }
  return cachedClient;
}

export interface EncryptArgs {
  round: number;
  plaintextHex: string;
}
export interface EncryptResult {
  ciphertextHex: string;
}
export interface DecryptArgs {
  ciphertextHex: string;
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

// Decrypt an armor-stripped age payload. Reads R from the stanza, fetches the
// round signature, and STREAM-decrypts. Throws if the round is not yet public.
export async function decrypt(args: DecryptArgs): Promise<DecryptResult> {
  const ageBinary = Buffer.from(args.ciphertextHex, "hex").toString("binary");
  const plaintext = await timelockDecrypt(ageBinary, client());
  return { plaintextHex: plaintext.toString("hex") };
}
