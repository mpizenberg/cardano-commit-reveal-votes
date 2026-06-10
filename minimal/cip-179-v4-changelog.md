# CIP-179 v4 changelog

Breaking changes introduced in `spec_version = 4`, with rationale. Several items
converge CIP-179's question/answer and vocabulary layers with CIP-191
(Ekklesia); the cross-standard comparison — including what was deliberately
*not* imported — lives in [cip-179-vs-cip-191.md](./cip-179-vs-cip-191.md).
A final section recaps the `v2 → v3` changes for continuity, since the published
spec jumped through v3 on the way to v4.

## 1. Question type tags renumbered; `custom` moved to tag 0

Tags are now `0 = custom`, `1 = single-choice`, `2 = multi-select`,
`3 = ranking`, `4 = numeric-range`, plus the two new types below; answer tags
match their question tag. A fixed tag `0` gives the extension type a stable,
predictable home, so future built-in types append at higher tags without ever
renumbering it. With the spec still `Proposed` and effectively no production
users, this is the cheapest moment to adopt the convention.

## 2. New question types: `points_allocation` (5) and `rating` (6)

`points_allocation_question` distributes a fixed `budget` of points across
options; `rating_question` rates options on a `rating_scale`. Answers are lists
of `(option_index, value)` pairs. The scale is a sum type: a
`numeric_constraints` grid (presented as numbers, e.g. 1–5) or an ordered
worst-to-best label list (presented as text, e.g. `["bad","meh","good"]`; a
level count in external-content mode). The rating answer is **always an
integer** — a grid value, or the 0-based label index — so tallying stays numeric
and compact regardless of presentation, and ordinal labeled scales need no
single-choice-per-item workaround. Both types cover common polling needs the
option-only types cannot express.

## 3. `min` constraints on multi-select and ranking

`multi_select_question` gains `min_selections`/`max_selections` and
`ranking_question` gains `min_ranked`/`max_ranked`, all explicit positional
fields — completing the constraint surface (previously only `max` existed) and
resolving the long-standing TODO in the spec. `min_selections = 0` is allowed: a
present, empty selection (`[2, q_idx, []]`) is a valid, tallied "none selected"
answer — e.g. "which of these do you deem acceptable?" answered with none —
deliberately distinct from omitting the question (abstain), since CBOR
distinguishes a present empty array from an absent answer item. The multi-select
answer is therefore `[2, uint, [* uint]]`. Ranking keeps `min_ranked >= 1`
(ranking zero options is not a meaningful present answer and collapses into
abstain), so its answer stays `[3, uint, [+ uint]]`.

## 4. Per-question `required` flag

Every question type ends with an optional trailing `bool` (default `false`);
when `true`, a response omitting the question is invalid as a whole. Lets
creators force an explicit answer where abstention is unacceptable; pairs with
abstain-by-omission (next item).

## 5. Abstain by omission

A question with no answer item in a response is an abstain on that question.
The v2 rule that an empty multi-select selection is unconditionally valid is
removed: empty is now valid only when `min_selections = 0` and means "none
selected", not abstain (item 3). Encoding abstention as *absence* costs zero
bytes and needs no dedicated marker, while the distinction that matters is
preserved: a respondent who never submits is a non-participant, not an
abstainer. Authors wanting a *counted, selectable* abstain can still add an
explicit "Abstain" option.

## 6. `role_weighting` → `eligible_roles`; weighting modes removed

The role→weighting-mode map becomes a plain set of eligible roles; the
`weighting_mode` enumeration and the normative "Weighting Semantics" section are
deleted; a new `Owner` role (4) is added. The old field conflated *eligibility*
(who may respond and which credential they prove — affects validation, useful as
a UI key hint; stays in the definition) with *weighting* (how a selection
becomes influence — changes nothing the respondent signs; purely downstream
interpretation). The `CredentialBased / StakeBased / PledgeBased` enumeration is
inherently incomplete (it cannot express quadratic voting, Borda counts, or
custom formulas), so weighting moves entirely outside CIP boundaries: the same
recorded vote set can be re-tallied under any rule, and the on-chain definition
stays honest about what the chain enforces. `end_epoch` remains as validity
cutoff and canonical snapshot reference for whoever does the weighting.

This dissolves two earlier questions ("should Stakeholder also allow
CredentialBased?", "should Owner be CredentialBased-only?"): without weighting
in the schema, both roles are just eligibility/UI hints. `Owner` means "prove
control of a payment/spending credential", suited to e.g. NFT-gated surveys
where the gating is enforced off-chain. A CIP-151 calidus hot key is an
alternative proof mechanism for the SPO role, not a distinct role.

## 7. `content_anchor` primitive (URI + blake2b-256 hash)

One tamper-evident off-chain reference type `[uri, hash]`, reused in three
places: (1) optional external survey **presentation text** (new optional
`survey_definition` field), (2) the **custom-method schema** (replacing the
inline `method_schema_uri` + `method_schema_hash` pair), (3) an optional
per-response **voter rationale** (new optional `survey_response` field, aligned
with Cardano governance's CIP-100/CIP-108 anchor conventions).

External definitions enable much larger surveys at small on-chain cost while
moving only presentation text off-chain: the structural skeleton (question
count, type tags, all constraints, eligible roles, end_epoch, owner, submission
mode) stays on-chain, so responses remain validatable and talliable from chain
data alone (answers reference option *indices*) and a missing off-chain document
costs only labels. A bare-reference replacement was rejected — it would make the
survey's interpretability depend on off-chain availability. In external mode,
option-bearing questions may store an option **count** (`uint`) instead of
labels; the CBOR shapes are distinct.

## 8. Method Identifier Registry (URN cross-walk)

A table maps each integer tag to an interop URN (e.g.
`urn:cardano:poll-method:ranking:v1`). URNs aid interoperability with standards
that name methods with strings, but never appear in the CBOR — that would
reintroduce the text bloat the encoding exists to avoid. The tag is the on-chain
identifier; the URN is a documentation/registry alias (mirrorable into CIP-10);
the only URN in data is the `custom` type's anchor URI. The suffix versions a
method's *semantic contract*, not this CIP's document version: `single-choice`,
`multi-select`, and `numeric-range` go to `:v2` because their `:v1` (CIP-179
v1's string-based encoding) is materially redefined here — CBOR-first encoding,
abstain-by-omission, meaningful empty multi-select — and reusing `:v1` would be
a contract collision; the other three start at `:v1`. The mapping to CIP-191's
method names and URNs (including its repointing at `:v2`) is in the
[comparison doc](./cip-179-vs-cip-191.md).

## 9. Top-level records → integer-keyed maps (forward-compat)

`survey_definition` and `survey_response` move from positional CBOR arrays to
deterministically-encoded **integer-keyed maps** (keys `0..n`, same field order
as before); optional fields get fixed keys instead of trailing positions; the
nested discriminated unions (questions, answers, `content_anchor`, `survey_ref`,
option lists) stay tagged positional arrays. Maps are Cardano's forward-compat
idiom — Conway's `transaction_body` is one precisely so new fields could be
added at new keys across eras without renumbering. The *definition* is
low-volume (one per survey) and the structure most likely to accrete optional
fields (`start_epoch`, quorum hint, category, a second anchor, …), so key
overhead is negligible where flexibility is most valuable. The *response* gains
less in bytes, but the deferred CIP-8 work adds optional signature material and
a nonce alongside the already-optional rationale — several independent optionals
an array cannot express without null placeholders or brittle trailing-order
rules, while the ~5 bytes of keys are dwarfed by credential and answers. The
nested unions evolve by adding new *tags*, not fields, so maps there would only
bloat them. Encoders MUST emit these maps deterministically (integer keys
ascending, no duplicates — plain numeric order per RFC 8949 §4.2) so
hashing/equality/dedup over payloads stays unambiguous; decoders SHOULD ignore
unrecognized keys (reserved for future versions).

## 10. Governance linkage decoupled from eligibility

A linked survey no longer restricts who may respond and no longer requires a
`voting_procedures` vote on the linked action: all `eligible_roles` participate
exactly as standalone, and the vote becomes an **optional binding** —
cross-checked when present (voter credential matches the response credential,
votes on the linked action, Conway voter tag matches the claimed role), not a
failure when absent. Credential proof is now an explicit either/or:
`required_signers` (mechanism A) *or* a ledger-validated binding (mechanism B,
sufficient alone since the ledger already enforced the voter's witness when
accepting the vote; the only mechanism for Plutus-script credentials).

The prior rule (inherited from v3) made the governance vote the proof mechanism
for linked responses, conflating discovery, eligibility, and credential proof —
and silently excluding the two roles without a Conway voter type (Stakeholder,
Owner). An Info Action linking a survey is essentially advertising it; that
should widen reach, not narrow it, and standalone proof + ledger role-validation
already cover every role. The binding is kept rather than dropped because it is
the *only* path to ledger-evaluated **Plutus-script** verification (Conway voter
tags 1 and 3; the ledger evaluates the voting redeemer, which the
`required_signers` path cannot — metadata has no redeemer tag), and it lets
voter roles correlate "voted X on the action, answered Y on the survey." The
credential-proof rules now distinguish key / native-script / Plutus-script
explicitly, and the "Plutus script credentials" limitation is generalized beyond
standalone surveys.

## Deferred (open design questions, not implemented in v4)

- **CIP-8 message-signing proof / calidus support** — would let SPOs prove the
  SPO role via a CIP-151 calidus hot key and enable batched third-party
  submission of message-signed responses. Needs a design pass on: the signed
  payload (replay binding via `survey_ref` + a per-response nonce), where the
  signature/recovered key live in the response, within-survey replay handling
  (the `(survey_ref, role, credential)` dedup helps), and how batched submission
  is expressed in the label `17` payload. (Correction from earlier discussion:
  `required_signers` is *not* coupled to who pays the fee — it just guarantees a
  credential witnessed the tx; CIP-8's genuine advantages are message-signing
  credential types and offline/aggregated submission.)
- **Canonical tally interchange format** — a *recommended, non-normative*
  per-method tally shape for cross-tool result comparison on shared test
  vectors; worth designing in its own pass.

## Earlier: changes introduced in v3 (v2 → v3)

Recapped for continuity; independent additions, all carried forward into v4.
(Field names use v4's `snake_case` documentation convention; names never appear
in the encoding.)

### v3.1 Sealed submission mode (timelock encryption / Drand `tlock`)

`survey_definition` gains `submission_mode`: `[0]` **public** (plaintext answer
items, as in v1/v2) or `[1, drand_chain_hash, round, padding_size]` **sealed**,
where a response carries a `tlock` ciphertext (new `chunked_bytes` primitive)
instead of plaintext; `response_answers` accepts either form, distinguished by
CBOR shape (arrays vs. byte strings). Answers encrypted at submission become
decryptable by anyone — and by no one earlier, not even the survey owner — once
`round` publishes on the pinned Drand chain; `padding_size` pads plaintexts so
ciphertext length does not leak answer content. This enables **delayed-reveal**
polling with no trusted operator or reveal phase — the trustless, fully-on-chain
analogue of commit-reveal voting (this repository's namesake) — and is *not*
permanent secrecy. The mode is named **sealed** (sealed-ballot metaphor): it
reads as the opposite of "public" without implying permanent secrecy the way
"private"/"encrypted" would; *timelock encryption* / *Drand `tlock`* names the
underlying mechanism.

### v3.2 `spec_version` restored to `survey_response`

Reinstated as the response's first element (present in v1, dropped in v2 on the
assumption the referenced survey supplies it); it MUST match the referenced
definition's. It lets a response be decoded on its own — answer encoding,
plaintext-vs-sealed shape — without first resolving the survey. (v4 keeps it as
map key `0`.)

### v3.3 `survey_definition` field reorder

Fixed-size header fields now precede the variable-length `questions` array:
`[spec_version, owner, title, description, role_weighting, end_epoch, submission_mode, questions]`
(v2 placed `questions` at position 4). Question indices are unchanged, so answer
references are unaffected. Keeping the single variable-length field last gives
every header field a stable position — moot once v4 turned these records into
maps ([item 9](#9-top-level-records--integer-keyed-maps-forward-compat)), but it
set the `submission_mode`/`questions` placement v4 inherited as keys 6 and 7.
