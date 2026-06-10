# CIP-179 vs CIP-191 (Ekklesia)

Both standards record structured community votes on Cardano and deliberately
leave weighting, eligibility policy, and tabulation thresholds out of scope, so
the same recorded vote set can be re-tallied under any rule. They differ in
architecture, trust model, and encoding. CIP-191 aligns its question/answer
format with CIP-179 and states it will revise its method URIs to match CIP-179
when finalized. This document collects every cross-standard comparison so the
CIP-179 specification ([cip-179.md](./cip-179.md)) and changelog
([cip-179-v4-changelog.md](./cip-179-v4-changelog.md)) do not need to inline
them.

References: CIP-179 ([CIPs PR #1107](https://github.com/cardano-foundation/CIPs/pull/1107)),
CIP-191 ([CIPs PR #1207](https://github.com/cardano-foundation/CIPs/pull/1207)).

## Architecture and trust model

|                    | CIP-179                                                                                           | CIP-191                                                                                             |
| :----------------- | :------------------------------------------------------------------------------------------------ | :-------------------------------------------------------------------------------------------------- |
| Layer              | L1 transaction metadata (label `17`)                                                              | Hydra L2 head + L1 settlement                                                                       |
| Primary data store | On-chain (off-chain anchors optional, additive)                                                   | IPFS (on-chain datums hold hashes/CIDs only)                                                        |
| Operator           | None — anyone submits transactions                                                                | Voting authority runs the head and middleware                                                       |
| Verification       | Everything validated and tallied from on-chain data alone                                         | Audit: merkle proofs + hash commitments against IPFS evidence                                       |
| On-chain artifacts | Metadata payloads (definitions, responses, cancellations)                                         | CIP-67 token pair (600 definition / 601 instance) + per-voter tokens in-head                        |
| Cost/throughput    | One L1 fee per response transaction (batchable)                                                   | High-throughput voting inside the head; a few L1 transactions total                                 |
| Availability       | Survey remains fully interpretable from chain even if anchored text is lost (only labels missing) | Ballot definition and evidence live on IPFS; if unpinned, the ballot is not reconstructible from L1 |

CIP-179 v4 deliberately converges with CIP-191 at the question/answer and
vocabulary layers **without** importing the L2 / IPFS-as-primary-store /
operator-run architecture, which would undercut CIP-179's trustless,
fully-on-chain model. Conversely, CIP-191 scales to elections with thousands of
voters, which per-response L1 fees make impractical under CIP-179.

This availability difference also drove CIP-179's external-content design: a
survey definition may move _presentation text_ off-chain behind a
`content_anchor`, but the structural skeleton (question count, type tags, all
constraints) always stays on-chain. A bare-reference replacement was rejected
because it would import CIP-191's availability dependence wholesale.

## Method mapping

CIP-179 identifies question types on-chain by integer tag and documents a URN
alias per tag (URNs never appear in CIP-179 metadata). CIP-191 names methods
with strings and maps them to URNs in its `Vote methods` table.

| Tag | CIP-179 type      | CIP-179 interop URN                            | CIP-191 method            | CIP-191 URN                                       |
| :-- | :---------------- | :--------------------------------------------- | :------------------------ | :------------------------------------------------ |
| 0   | Custom            | (per-method, via the anchor URI)               | —                         | —                                                 |
| 1   | Single-choice     | `urn:cardano:poll-method:single-choice:v2`     | `single-choice`, `binary` | `urn:cardano:poll-method:single-choice:v1`        |
| 2   | Multi-select      | `urn:cardano:poll-method:multi-select:v2`      | `multi-choice`            | `urn:cardano:poll-method:multi-select:v1`         |
| 3   | Ranking           | `urn:cardano:poll-method:ranking:v1`           | `ranked`                  | `urn:ekklesia:poll-method:ranked-choice:v1`       |
| 4   | Numeric-range     | `urn:cardano:poll-method:numeric-range:v2`     | `range`                   | `urn:cardano:poll-method:numeric-range:v1`        |
| 5   | Points-allocation | `urn:cardano:poll-method:points-allocation:v1` | `weighted`                | `urn:ekklesia:poll-method:weighted-allocation:v1` |
| 6   | Rating            | `urn:cardano:poll-method:rating:v1`            | `likert`                  | `urn:ekklesia:poll-method:likert:v1`              |

Notes:

- **`binary` collapses into single-choice.** CIP-191's `binary` (fixed
  Yes/No/Abstain) is just single-choice with explicit options in CIP-179, so it
  needs no tag of its own.
- **URN repointing.** The `:v1` URNs CIP-191 references were defined by CIP-179
  v1 (the string-based encoding). CIP-179 v4 materially redefines those methods
  (CBOR-first encoding, abstain-by-omission, meaningful empty multi-select), so
  it bumps them to `:v2`; reusing `:v1` would be a semantic-contract collision.
  CIP-191 states its URI column reflects CIP-179's draft state and will be
  revised when CIP-179 finalizes.
- **New `urn:cardano` definitions.** `ranking`, `points-allocation`, and
  `rating` had no prior `urn:cardano:poll-method:*` definition (CIP-191 carries
  them under `urn:ekklesia:*`), so they begin at `:v1`. CIP-179 keeps its own
  method names — `ranking`/`points-allocation`/`rating` are judged clearer than
  Ekklesia's `ranked`/`weighted`/`likert`.

## Question constraints

| Concern             | CIP-179 v4                                                         | CIP-191 (0.3.0)                                                            |
| :------------------ | :----------------------------------------------------------------- | :------------------------------------------------------------------------- |
| Multi-select bounds | Explicit `min_selections` (may be `0`) and `max_selections`        | `minSelections` (default 1) and `maxSelections` (default `options.length`) |
| Ranking             | `min_ranked`..`max_ranked` range, `min_ranked >= 1`                | `rankCount`: rank _exactly_ that many options                              |
| Rating scale        | Numeric grid **or** ordered text labels (answer always an integer) | `ratingRange` numeric grid only                                            |
| Rating coverage     | Respondent MAY rate a subset of options                            | Exactly one rating per non-abstain option                                  |
| Required answer     | `required` flag (default false)                                    | `requireAnswer` flag (default false) — same intent                         |
| Option identity     | Answers reference 0-based option _indices_                         | Options carry an explicit integer `value`                                  |

The v4 `min` constraints complete CIP-179's constraint surface and match
CIP-191's `minSelections`; the `required` flag mirrors CIP-191's
`requireAnswer`.

## Abstain semantics

CIP-191 encodes abstention explicitly: `abstain: true`, mutually exclusive with
`selection`, surfaced as a distinct bucket in results. CIP-179 v4 expresses the
same intent by _omission_: a question with no answer item is an abstain, which
costs zero bytes — more data-efficient than a dedicated field. Both let authors
additionally offer a counted, selectable "Abstain" option, and both treat a
respondent who never submits as a non-participant rather than an abstainer.
CIP-179 additionally distinguishes a present, empty multi-select selection
("none selected", valid when `min_selections = 0`) from an omitted question.

## Roles, eligibility, and weighting

|                             | CIP-179 v4                                                 | CIP-191 (0.3.0)                                                                                                                  |
| :-------------------------- | :--------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------- |
| Role space                  | DRep, SPO, CC, Stakeholder, Owner (integers 0–4)           | `drep`, `pool`, `stake` (lowercase strings; legacy `DRep`/`SPO`/`CC` rejected)                                                   |
| CC                          | Supported (hot credential)                                 | Not supported                                                                                                                    |
| Payment credential          | `Owner` role (off-chain eligibility gating, e.g. NFTs)     | Rejected — voters fall back to their stake credential                                                                            |
| Weighting in the definition | None — `eligible_roles` only; weighting fully out of scope | `roleWeighting` tabulation _hint_ (`CredentialBased`/`StakeBased`/`PledgeBased`); infrastructure still publishes raw counts only |

CIP-179's `SPO` and CIP-191's `pool` are the same role. A CIP-151 calidus hot
key is an alternative _proof mechanism_ for that role, not a distinct role —
CIP-191 collapses `calidus` voter IDs into `pool` accordingly. CIP-179 v1–v3
carried a `role_weighting` map with the same mode enumeration CIP-191 still
hints at; v4 removed it because the enumeration is inherently incomplete (no
quadratic voting, Borda, custom formulas) and weighting changes nothing the
respondent signs. CIP-191 reaches the equivalent operational outcome by
publishing raw participation only and pushing weighting to the voting
authority's tabulation layer.

## Identity, signatures, and replay

- **CIP-191** uses CIP-8 (`COSE_Sign1`) message signing: voters sign a payload
  binding `ballotId` and a monotonic `nonce` (replay protection via the voter
  token's `version`); multisig voters provide one witness per cosigner plus the
  native script; calidus hot keys are supported today.
- **CIP-179** uses transaction-level witnesses: `required_signers` for keys,
  native-script satisfaction for scripts, and an optional `voting_procedures`
  binding (the only path for Plutus-script credentials). An optional CIP-8
  proof mode — which would also enable calidus-based SPO proof and batched
  third-party submission, the things CIP-191 already gets from CIP-8 — is an
  open design question; CIP-191's payload design (replay nonce, witness array,
  script satisfaction at evidence assembly) is the closest prior art for that
  pass.

## Results and auditability

CIP-191 commits a fully-specified `results.json` (hashed into the (601) datum,
re-derivable by auditors), which forces a rigid normative per-method tally
schema, plus merkle inclusion proofs and a normative auditor algorithm — all
driven by its hash-and-audit commitment model. CIP-179 has no such commitment:
tallies are derived independently from on-chain data and no tally artifact is
committed, so it needs no rigid schema. A _recommended, non-normative_
interchange shape for cross-tool tally comparison is a deferred CIP-179 work
item; CIP-191's `results.json` (per-option counts with per-role
`resultsByGroup` and an explicit abstain bucket) is useful prior art for it.

## Voter rationales

CIP-179 responses may carry an optional `content_anchor` referencing an
off-chain rationale document (CIP-100/CIP-108 style). CIP-191's vote-evidence
schema has no rationale field; this is a CIP-179 addition with no Ekklesia
counterpart.

## Sealed (delayed-reveal) responses

CIP-179 defines a sealed submission mode using timelock encryption (Drand
`tlock`): answers are undecryptable by anyone until a target round publishes.
CIP-191 has no equivalent — votes are plaintext inside the head and in the
published evidence.

## Versioning

CIP-179 uses a single integer `spec_version` carried in every definition and
response, with integer-keyed top-level maps absorbing backward-compatible field
additions without a bump. CIP-191 versions its on-chain datums with a small
integer and its off-chain JSON documents with a semver `specVersion` string
(`"0.3.0"` as-built, with an `additionalProperties`-based extensibility model
arriving in 0.4.0).
