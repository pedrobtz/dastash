# A formal model of a cache

An abstract model of the class of systems that `diskcache`, `polars-diskcache`, `storr`,
`requests-cache` and `dastash` all belong to. The point is not formality for its own sake:
it is that once the model is written down, most of the design rules in `design.md` stop
being advice and become **theorems**, and the places where the implementations differ
become **choices of parameter** rather than differences of kind.

Read `prior-art-diskcache.md` for what the implementations do. This says what they *are*.

---

# 0. What the model has to explain

A model earns its place by deriving things that were previously asserted. This one is
built to explain seven facts:

1. Why a cache may forget but a store may not — and where exactly the line is.
2. Why lazy expiry is not an optimisation but the definition.
3. Why `expire`, `evict(tag)`, `cull` and `clear` are one operation.
4. Why every eviction policy is an index, and why the choice of policy is
   *semantically free*.
5. Why LRU makes reads into writes and least-recently-stored does not.
6. Why the blob must be written before the record and deleted after it.
7. Why a cache may run with `fsync` disabled and a store may not.

Each is a numbered result below.

---

# 1. Signature

The model is parameterised by eight things. An implementation is a choice of all eight.

| Parameter | Meaning |
|---|---|
| `K` | the key space |
| `V` | the value space |
| `≈ ⊆ V × V` | **semantic identity** on values: when two values count as the same answer |
| `Θ` | time: a totally ordered set with a greatest element `∞` |
| `T` | tags |
| `D` | datasets (namespaces with schemas) — §9 |
| `R` | revisions: a totally ordered set — §10 |
| `≼` | the eviction preorder on entries — §7 |

`≈` is the parameter people forget, and it is the one that does the most work. It is not
equality: two values are the same *answer* if a user cannot tell them apart, and that is a
per-implementation decision (§11).

Write `V⊥ = V ∪ {⊥}`, where `⊥` is "absent". `⊥` is not a value; it is the absence of one.

---

# 2. State: a retained subset of a write history

The usual move is to model a cache as a partial map `K ⇀ V`. That is too poor: it cannot
express versioning, and it cannot express what a crash does. The right state is a pair.

**Definition 2.1 (write).** A *write* is a record

```
w = (key, value, born, dies, tags, size)  ∈  K × V × Θ × Θ × P(T) × ℕ
```

with `born ≤ dies`. `dies = ∞` means "never expires".

**Definition 2.2 (history and retention).** A cache state is a pair `(H, R)` where `H` is
the sequence of writes the system has been asked to perform and `R ⊆ H` is the subset it
has **retained**.

Everything a cache does is one of two things: append to `H`, or shrink `R`.

**Definition 2.3 (liveness).** `live_t(w) ≡ w.born ≤ t < w.dies`.

Note `live` is *antitone* in `t`: once dead, always dead.

**Definition 2.4 (observation).** For `t ∈ Θ` and `k ∈ K`:

```
get_t(R, k)  =  w.value   where w = argmax_{w.born} { w ∈ R : w.key = k ∧ live_t(w) }
             =  ⊥         if that set is empty
```

Reads see **the most recent retained live write** for the key.

That is the entire semantics. Everything below is consequences.

---

# 3. The two axioms

**Axiom I — Soundness.** `R ⊆ H`.

The cache never returns a value that was never written. This is the axiom no
implementation may violate; violating it is *corruption*, not forgetfulness.

**Axiom II — Forgetfulness.** `R` may shrink at any time, for any reason, with no
notification.

That is it. A cache is a system satisfying I and II.

**Definition 3.1 (store).** A *store* is a cache additionally satisfying

```
Axiom III — Persistence.  R contains the latest write for every key ever written.
```

**Result 0 (the cache/store line).** A store is a cache that never forgets. Formally, the
read-after-write law weakens from equality to membership:

```
store:   get_t(set(R, k, v), k)  =  v
cache:   get_t(set(R, k, v), k)  ∈  { v, ⊥ }        (and, without versions, only these)
```

Every difference between `storr` and `diskcache` reduces to this one line. It is also why
a cache and a store cannot share an API contract even when they share an API surface: the
caller of a store may rely on the value being there, and the caller of a cache may not.

---

# 4. Operations

## 4.1 The write side — `H` grows

```
set(k, v, e, τ)   H := H ⌢ ⟨(k, v, now, now+e, τ, |v|)⟩
                  R := R ∪ {that write} ∖ {prior retained writes for k}      (unversioned)
                  R := R ∪ {that write}                                      (versioned, §10)

add(k, v, …)      = set(…)  if get_now(R,k) = ⊥;  no-op otherwise
touch(k, e)       replaces the retained write for k by one with dies := now+e
delete(k)         R := R ∖ {w ∈ R : w.key = k}
pop(k)            = (get_now(R,k), delete(k)) — atomically
```

Two things to notice. `add` is defined **in terms of the observation**, so an expired
entry is a legal target for `add` — absence and expiry are the same thing to a caller
(§5). And in the unversioned model, `set` performs a *forget* as part of its definition:
overwrite is destructive because retention is capped at one write per key.

## 4.2 The maintenance side — `R` shrinks

**Definition 4.1 (forget).** For a predicate `P` on writes,

```
forget_P(R)  =  R ∖ { w ∈ R : P(w) }
```

**Result 3 (four operations are one).** Every maintenance operation in every
implementation surveyed is `forget_P` for some `P`:

| Operation | `P(w)` |
|---|---|
| `expire()` | `¬live_t(w)` |
| `evict(τ)` | `τ ∈ w.tags` |
| `cull()` | `w ∈ policy(R, n)` — §7 |
| `clear()` | `true` |
| `delete(k)` | `w.key = k` |
| overwrite of `k` | `w.key = k` (as part of `set`) |
| **crash rollback** | `w ∉ H↾[0,n]` — §13 |

In SQLite they are six `DELETE … WHERE` statements; in an ordered key-value store they are
six bounded scans. They differ only in `P`, and `P` differs only in which index answers it
cheaply. This is why `design.md` §9.1 can write expiry and eviction as the same loop.

---

# 5. Expiry is not an operation

**Result 2 (expiry is observationally neutral).** For all `R`, all `t' ≥ t`, all `k`:

```
get_{t'}( forget_{¬live_t}(R), k )  =  get_{t'}(R, k)
```

*Proof.* `forget_{¬live_t}` removes exactly the writes with `¬live_t(w)`. By antitonicity
of `live`, `¬live_t(w) ⟹ ¬live_{t'}(w)`, so every removed write was already excluded from
the `argmax` in Definition 2.4 at time `t'`. The set being maximised over is unchanged. ∎

So calling `expire()` cannot change what any read returns, ever. **Lazy expiry is
therefore not an optimisation — it is forced.** Expiry lives in the *observation* function
(Definition 2.4) and `expire()` is purely a resource-management operation that reclaims
space already semantically dead.

This is the formal content of `design.md` §8.3 and of diskcache's identical behaviour: a
read never has to write in order to respect a deadline, because the deadline was never a
property of the state in the first place.

**Corollary 5.1.** `expire()` may be run at any time, by any process, in any order, with
no coordination. It commutes with everything.

---

# 6. The retention order

**Definition 6.1.** `R ⊑ R'` iff `R ⊆ R'`. Read: `R` knows no more than `R'`.

`(P(H), ⊑)` is a complete lattice with bottom `∅` (an empty cache) and top `H`.

**Result 6.2 (maintenance is monotone downward).** `forget_P(R) ⊑ R` for every `P`.

**Result 6.3 (soundness is downward-closed).** If `R` satisfies Axiom I then so does every
`R' ⊑ R`.

Together: **forgetting can never make a cache unsound.** Any subset of any sound state is
sound. This is why an implementation may throw data away whenever it likes — under memory
pressure, on a policy, at random — without needing to argue about correctness. It is also
why the *only* thing that has to be got right is Axiom I.

**Result 6.4 (the write side is the only unsound direction).** The single way to violate
Axiom I is to make `R` contain something not in `H` — i.e. to return bytes that were never
written. Every genuine correctness bug in a cache is of this form: a dangling reference
read as a value (§12), a hash collision, a torn write, a decode of the wrong blob.

That is a useful thing to know when deciding where to spend testing effort.

---

# 7. Eviction

`cull` is the only operation whose effect is not determined by the state, because it
requires a *choice* of victims.

**Definition 7.1 (policy).** A policy is a choice function `policy : P(H) × ℕ → P(H)` with
`policy(R,n) ⊆ R` and `|policy(R,n)| ≤ n`.

**Definition 7.2 (order-induced policy).** Given a total preorder `≼` on writes,
`policy_≼(R,n)` = some `≼`-least `n` elements of `R`.

Every policy in every implementation is order-induced:

| Policy | `≼` |
|---|---|
| `least-recently-stored` | `w ≼ w' ⟺ w.born ≤ w'.born` |
| `least-recently-used` | `w ≼ w' ⟺ w.touched ≤ w'.touched` |
| `least-frequently-used` | `w ≼ w' ⟺ w.hits ≤ w'.hits` |
| `none` | the empty policy |

**Result 4a (why every policy is an index).** `policy_≼(R,n)` is computable in `O(n)` — as
opposed to `O(|R|)` — precisely when `≼` is materialised as a sorted structure over `R`.
A cull is then "read the first `n` in `≼` order", a bounded scan from one end.

This is the whole reason the index exists, in both SQLite and mdbx. And it is where the
abstract model touches `design.md` §5: in an ordered key-value store, "materialised as a
sorted structure" means *the encoding of `≼`'s ranking function into bytes must be
order-preserving*. A non-monotone encoding does not produce a slow cull; it produces the
wrong victims, silently.

**Result 4b (eviction policy is semantically free).** Let `A` and `B` be two caches
identical except in policy. Both satisfy Axioms I and II. No sequence of operations can
distinguish them *as caches* — only as resource consumers.

*Proof.* By Result 6.3, any `forget` preserves soundness; Axiom II places no constraint on
which writes are forgotten. Both are therefore correct implementations of the same
specification. ∎

This has three practical consequences, all of which appear as engineering decisions in the
implementations:

- An implementation may **approximate** `w.touched` — batching, sampling, or dropping
  updates entirely — without becoming incorrect. (`design.md` §9.3's read journal.)
- Losing the in-memory access-time buffer to a crash costs **eviction accuracy, not
  correctness**, because eviction accuracy is not a correctness property.
- A cache may downgrade LRU to LRS under load and remain a correct cache.

**Result 5 (why LRU makes reads into writes).** `≼` is a preorder on writes, so it is a
function of the fields of `w`. If `≼` depends only on fields fixed at write time
(`born`, `size`), then `get` need not modify state. If `≼` depends on `touched` or `hits`,
then by Definition 7.2 the policy depends on values that only a *read* can update, and
`get` must have type

```
get_t : P(H) × K  →  V⊥ × P(H)
```

— a state transformer, not an observation.

So the split is exact: **`least-recently-stored` is the unique policy among the four that
keeps `get` pure.** That is not a coincidence in diskcache's defaults; it is the reason for
them, and the same reason drives `design.md` D4.

---

# 8. Freshness: one deadline is a special case of two

`diskcache` gives a write one deadline. `requests-cache` gives it a lifecycle. Both are
instances of a two-deadline model.

**Definition 8.1.** Extend a write with `fresh_until ≤ usable_until`, and define

```
t < w.fresh_until                        :  fresh          usable with no contact
w.fresh_until ≤ t < w.usable_until       :  stale          usable only under a mode
t ≥ w.usable_until                       :  dead           never usable
```

Observation is then indexed by a **mode** `m ∈ {strict, stale_ok}`:

```
live_t^strict(w)    ≡  t < w.fresh_until
live_t^stale_ok(w)  ≡  t < w.usable_until
```

| System | Instance |
|---|---|
| `diskcache`, `dastash` v1 | `fresh_until = usable_until`; the modes coincide |
| `polars-diskcache` | `fresh_until = usable_until = ∞`; nothing ever expires |
| `requests-cache` | the two differ; `stale_ok` is `stale-if-error` |
| `storr` | `= ∞`, plus Axiom III |

Result 2 survives verbatim with `live` replaced by `live^m`, for each fixed mode. So lazy
expiry stays forced, and `stale-if-error` is not a new mechanism — it is the same state
read through a weaker liveness predicate. That is worth knowing before building it: it
needs a second field, not a second subsystem.

---

# 9. Datasets, schemas and queries

So far `K` was opaque. Giving it structure is what separates a cache from a catalogue.

**Definition 9.1 (schema).** A dataset `d ∈ D` has a schema: a finite map from field names
to types, `S_d : F_d → Type`. The key space of `d` is the **dependent product**

```
K_d  =  Π_{f ∈ F_d} ⟦S_d(f)⟧
```

and the global key space is the **dependent sum**

```
K  =  Σ_{d ∈ D} K_d  =  { (d, κ) : d ∈ D, κ ∈ K_d }
```

Keys are *total over the schema* (`dastash-design.md` §2.1) precisely because `K_d` is a
product: a partial assignment is not an element of a product type. And identity is
domain-separated by dataset because `K` is a sum: `(d,κ)` and `(d',κ)` are distinct
elements even when `κ` is the same tuple.

**Definition 9.2 (canonicalisation).** `canon_d : K_d → Bytes` with the requirement that it
is **injective**. Injectivity is exactly the statement that the induced equivalence
`κ ~ κ' ⟺ canon(κ) = canon(κ')` is trivial — i.e. that canonicalisation does not merge
distinct keys.

`canon` being a *section* of the storage layer (a right inverse exists: you can recover the
key from the bytes) is a stronger and separately useful property; it is what lets a store
print its own keys.

**Definition 9.3 (query as a fibre).** For a field `f`, let `π_f : K_d → ⟦S_d(f)⟧` be the
projection. Then

```
find(f = x)   =   π_f^{-1}(x)                     the fibre over x
find(f ∈ I)   =   π_f^{-1}(I)                     for an interval I
find(f = x, g = y)  =  π_f^{-1}(x) ∩ π_g^{-1}(y)
```

An **index over `f` is a materialisation of the fibration `π_f`**, and a multi-field query
is an intersection of fibres — which is why it is planned by selectivity, and why an
ordered index answers `f ∈ I` and `f = x` with the same machinery.

**Result 9.4 (why sort encoding is separate from canonical encoding).** Equality queries
need only that the index key determines the fibre, i.e. injectivity on the field. Range
queries need `sort_f : ⟦S_d(f)⟧ → Bytes` to be an **order-embedding**:

```
x ≤ y   ⟺   sort_f(x) ≤_lex sort_f(y)
```

These are different requirements. `canon` must be injective and *frozen* (it defines
identity, which cannot be revised once data exists); `sort` must be monotone and may be
*revised*, because an index is derived and can be rebuilt. Hence they are different
functions — `design.md` §3.3, and `plan.md`'s `canon_scalar`/`sort_scalar` split, derived.

---

# 10. Tags and versions

**Tags are a coarsening.** A tag assignment is a map `tags : H → P(T)`, and `evict(τ)`
forgets a whole fibre of it. Tags are therefore a *second, coarser addressing scheme* laid
over the same writes: the key addresses one write, the tag addresses a set. Nothing else
about them is special, which is why `evict(τ)` needed no new theory in §4.2.

**Versions are the removal of a constraint.** Recall from §4.1 that the unversioned model
imposes

```
∀k.  |{ w ∈ R : w.key = k }|  ≤  1
```

and that `set` maintains it by forgetting the prior write. Drop the constraint and:

**Result 10.1 (versioning makes `set` monotone).** Without the cap, `set` only ever grows
`R`; `R` shrinks only through explicit `forget`. Writes become monotone in `⊑`, and the
state becomes a join-semilattice under `∪`.

That is a real structural gain, and it is the reason `dastash-design.md` D2 keeps a
revision field from day one. Monotone state is mergeable state: two processes that each
appended writes can be reconciled by union, whereas two processes that each overwrote
cannot. Versioning is the difference between a structure that can be replicated and one
that cannot.

Definition 2.4 needs no change — it already reads the `argmax` by `born`, so a versioned
store resolves to "latest live revision" for free, and exposing older revisions is a
matter of offering a different observation function, not a different state.

---

# 11. Values, codecs and blobs

## 11.1 Codecs and the equivalence `≈`

A codec is a pair `enc : V ⇀ Bytes`, `dec : Bytes ⇀ V`.

**Definition 11.1 (lossless).** A codec is lossless on `V₀ ⊆ V` iff
`∀v ∈ V₀. dec(enc(v)) ≈ v`.

Every codec induces its own equivalence `v ≈_c v' ⟺ dec(enc(v)) ≈ dec(enc(v'))`, and
lossless means `≈_c` is no coarser than `≈`. Parquet has a strictly coarser `≈_c` than RDS
on R data frames — it merges values that differ in row names — which is the precise sense
in which it is lossy, and precisely why `codec_auto()` must not select it (`design.md`
§6.2).

**Result 11.2 (why an identifier forces a lossless codec).** If a system computes anything
from the *decoded* value and compares it against the key — `identify(dec(enc(v))) ⊑ k` —
then any collapse in `≈_c` that touches a field `identify` reads becomes a false verdict.
The requirement in `dastash-design.md` §2.6 is therefore not a quality preference but a
soundness condition on the composite.

## 11.2 Artifact identity is not blob identity

Let `h = hash ∘ enc : V ⇀ Hashes`.

**Result 11.3.** `h` does **not** factor through `≈`. That is, `v ≈ v'` does not imply
`h(v) = h(v')` — a codec version change, a compression setting, or attribute ordering
changes the bytes without changing the answer.

**Result 11.4 (the converse does hold).** Assuming collision resistance,
`h(v) = h(v') ⟹ enc(v) = enc(v') ⟹ dec(enc(v)) = dec(enc(v')) ⟹ v ≈_c v'`.

So **blob identity strictly refines value identity**. Content addressing therefore
deduplicates *bytes*, never *values*, and the containment is one-directional. This is
`dastash-design.md` §2.6 in two lines, and it is why a content hash can be trusted to
answer "is this the file the record means" and cannot be trusted to answer "have I seen
this value before".

## 11.3 The two-store composition, and Result 6

Real implementations split the state across two stores with different guarantees:

```
M : K ⇀ Hashes      metadata — transactional
B : Hashes ⇀ Bytes  blobs    — a filesystem, not transactional
```

and observation becomes a composition: `get_t(k) = B(M(k))`.

**Invariant 11.5 (no dangling references).** `ran(M) ⊆ dom B`.

Violating 11.5 means `get` reads a reference to bytes that do not exist — a violation of
Axiom I, the one axiom that admits no exceptions. Note that the *opposite* slack is
harmless: `dom B ∖ ran(M) ≠ ∅` is an **orphan**, invisible to every observation, costing
only space.

**Result 6 (the ordering rules are the only solutions).** Since `M` and `B` cannot be
updated atomically together, each of the two update paths passes through an intermediate
state. There are two orders each, and Invariant 11.5 selects one of them:

```
write:   B := B ∪ {h↦b}  ;  M := M[k↦h]        11.5 holds throughout      ✓
         M := M[k↦h]     ;  B := B ∪ {h↦b}     11.5 violated in between   ✗

delete:  M := M ∖ k      ;  B := B ∖ h         11.5 holds throughout      ✓
         B := B ∖ h      ;  M := M ∖ k         11.5 violated in between   ✗
```

Hence: **publish the blob before committing the record; commit the deletion before
unlinking the blob.** These are not two rules but one — *keep `B` a superset of `ran M` at
every instant* — and every crash window in `design.md` §7 is an application of it. The
asymmetry that makes orphans acceptable and dangling references fatal is exactly the
asymmetry of Invariant 11.5, which is an inclusion, not an equality.

**Result 11.6 (why refcounts must be transactional with `M`).** Define
`refs(h) = |M^{-1}(h)|`. Deleting `h` from `B` is safe iff `refs(h) = 0`. Since `refs` is a
function *of `M`*, any implementation that maintains it outside `M`'s transaction can
observe a `refs` that disagrees with `M` — and a `refs` that is spuriously zero deletes a
referenced blob, violating 11.5. Refcounts therefore live in the same transaction as the
records, necessarily.

---

# 12. Producers, and why single-flight is optional

**Definition 12.1 (resolution).** Given `produce : K → V`, define

```
resolve_t(R, k)  =  get_t(R,k)                        if that is ≠ ⊥
                 =  let v = produce(k) in set(k,v); v  otherwise
```

**Result 12.2 (the cache is invisible).** If `produce` is a function — deterministic up to
`≈` — then for every reachable retention set `R`,

```
resolve_t(R, k)  ≈  produce(k)
```

*Proof.* If `get_t(R,k) = ⊥`, immediate. Otherwise `get_t(R,k)` is the value of some write
`w` with `w.key = k`; by Axiom I that write came from a `set`, whose value was
`produce(k)`; by determinism of `produce` up to `≈`, it is `≈ produce(k)`. ∎

This is the theorem that justifies caching at all: **adding a cache does not change what
your program computes.** Note precisely what it requires — Axiom I (soundness) and
determinism of `produce` — and what it does *not* require: no completeness, no eviction
policy, no expiry accuracy, no coordination.

**Corollary 12.3 (single-flight is not a correctness mechanism).** Concurrent `resolve`
calls on a cold key may each invoke `produce`. By 12.2 every one of them returns a value
`≈ produce(k)`, and the retention set ends up holding one of them. Single-flight reduces
the *number of invocations*; it does not change the *result*.

It becomes load-bearing only when `produce` is not a function — when it has side effects,
costs money per call, or is nondeterministic — at which point the assumption of 12.2 has
failed and the cache was already outside the model.

This is the formal content of "leases are an optimisation, not a correctness mechanism",
and it is why that claim can be tested by running the suite with leases disabled.

---

# 13. Crashes

**Definition 13.1.** A crash is a transition `(H, R) → (H', R')` determined by the
durability mode.

| Mode | Effect | In the model |
|---|---|---|
| Full sync | none | `R' = R` |
| `SAFE_NOSYNC`, WAL with relaxed sync | recovery to the last steady commit | `R' = R ∩ H↾[0,n]` |
| `UTTERLY_NOSYNC`, torn writes | arbitrary | `R' ⊄ H` possible |

**Result 7 (crash ≈ eviction).** A crash whose recovery yields a **prefix** of the
committed history is a `forget_P` with `P(w) ≡ w ∉ H↾[0,n]`. By Result 6.2 it is a legal
transition of a cache; by Result 6.3 it preserves soundness.

*Therefore a cache may run with sync disabled, and a store may not.* The store's Axiom III
requires `R` to retain the latest write for every key; rollback deletes some of those.
The cache's Axiom II permits exactly this. **A crash under `SAFE_NOSYNC` is
observationally indistinguishable from an unlucky eviction**, and eviction is something a
cache is allowed to do at any moment for no reason.

**Result 7b (why `UTTERLY_NOSYNC` differs in kind).** A mode that can leave `R ⊄ H` —
returning bytes never written — violates Axiom I. That is not a stronger version of losing
data; it is the one thing no member of this model may do. The distinction between "may lose
recent transactions" and "may corrupt the database" is exactly the distinction between
Axiom II and Axiom I, and it is why the two cannot be traded off against each other.

**Result 7c (rollback interacts with versioning).** Under the unversioned cap of §4.1,
rolling back `set(k,v₂)` leaves `set(k,v₁)` as the greatest retained write, so `get`
returns `v₁` — an *older* value, not `⊥`. This is sound (Axiom I holds: `v₁` was written)
and it is a genuine hazard for callers who assume monotone freshness. It is also the
strongest practical argument for defaulting a general-purpose store to full durability
even though the model permits otherwise: the model's guarantees are about soundness, and a
user's expectations are usually about recency.

---

# 14. Concurrency

**Definition 14.1.** A concurrent execution is *linearizable* iff there is a total order on
its operations, consistent with real-time precedence, under which every operation's result
agrees with the sequential semantics of §2–§4.

Both SQLite-per-operation and MDBX-per-transaction give this directly: each operation is
one transaction, transactions are serialisable, and the commit order is the linearization.
`transact(f)` extends the unit of linearization from one operation to the block, which is
required for any invariant spanning two keys — including Invariant 11.5's refcounts.

Two observations the model makes sharp:

- **Readers need no coordination.** By §5, observation depends only on `R` and `t`; a
  snapshot read is a read of some `R'` with `R' ⊑ R` — sound by Result 6.3. Stale reads
  are indistinguishable from unlucky eviction, again.
- **`resolve` is not linearizable to a single `produce` call**, per Corollary 12.3. Its
  contract is at-least-once. Any implementation claiming exactly-once must say what it
  does when a lease expires mid-production, and the honest answer is that it degrades to
  at-least-once — which the model says is fine.

---

# 15. The implementations as instances

Every system in `prior-art-diskcache.md` and `design.md` is this model with the parameters
filled in.

| | `diskcache` | `polars-diskcache` | `dastash` | `storr` |
|---|---|---|---|---|
| `K` | picklable objects | `sha256(repr(bound args))` | canonical encoding of typed keys | strings |
| `V` | any picklable | `DataFrame`/`LazyFrame` | any R object | any R object |
| `≈` | pickle round-trip | Parquet round-trip | per codec, declared | RDS round-trip |
| `dies` | `now + expire` | `∞` | `now + expire` | `∞` |
| `T` | one tag | — | one tag | — |
| `D` | — | function identity | v2 (§9) | namespaces |
| `R` (revisions) | capped at 1 | capped at 1 | capped at 1, field reserved | capped at 1 |
| `≼` | 4 policies | size only | 4 policies | — |
| `B` addressing | random filename | hash of the **call** | hash of the **content** | hash of the content |
| Axiom III? | no | no | no | **yes** |

Three readings fall out:

- **`storr` is a store**, and every difference from `diskcache` follows from Axiom III
  rather than from any implementation choice.
- **`polars-diskcache` is a cache with `dies = ∞`** and no tags — a memo table with a size
  limit. Its distinctive choice is `B`'s addressing: hashing the *call* rather than the
  *content* means Result 11.4 does not apply, so it cannot deduplicate and its blob names
  carry no integrity claim.
- **`dastash` differs from `diskcache`** in exactly three parameters: `≈` is declared per
  codec rather than fixed by pickle, `B` is content-addressed with transactional refcounts
  (§11.6), and `K` is a specified injective encoding rather than an opaque pickle. The
  typed layer of `dastash-design.md` is the further step of giving `K` the structure of
  §9.

---

# 16. What the model does not capture

Stated so the model is not over-trusted.

- **Cost.** Everything here is about which answers are legal, not which are cheap. The
  entire subject of *why* one would use a cache is outside it. Result 4b says every
  eviction policy is equally correct; it does not say they are equally good, and choosing
  between them is the actual engineering problem.
- **The size limit.** `size_limit` is a constraint on `Σ_{w ∈ R} w.size`, and `cull` is the
  feedback loop enforcing it. Modelling that properly needs a dynamics — when the loop
  runs, whether it converges, what happens when a single value exceeds the limit — and none
  of that is here.
- **Partial reads.** Result 12.2 treats a value as atomic. `polars-diskcache`'s real
  selling point is that a cached `LazyFrame` is *queried in place*, which means the
  observation is not `get(k)` but `q(B(M(k)))` for a query `q`. That is a different and
  richer model.
- **Nondeterministic and effectful producers.** The moment `produce` is not a function,
  Result 12.2 fails and single-flight stops being optional. Most real producers — anything
  reading a live external system — are in this category, and the model has nothing to say
  about them beyond identifying where the assumption broke.
- **Trust.** Axiom I assumes `H` is what was actually asked for. Nothing here models an
  adversary, a corrupted mount, or two processes disagreeing about the configuration.
