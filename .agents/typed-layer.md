# dastash — the typed dataset layer

**Status:** deferred design. Nothing here is in the cache's v1. This layer sits above the
cache of `design.md` (§20 there) and is built after it ships.

A layer that resolves a declared, typed identity to a stored value, producing it on
demand when absent.

```text
Dataset × Key  ->  stash key  ->  record in mdbx  ->  value inline, or a blob
```

The cache answers "keep this value under this key, within these limits". This layer
answers "what *is* this value, and is it the one that was asked for": keys have a
declared schema, values have a producer, and a producer's output can be checked against
the key it was produced for.

---

# 0. What the cache already provides

This document began as the design of a standalone *typed artifact store*, with a plan of
its own. The cache took over everything that was storage, so what is left here is the
part that is actually new. Specifically, the layer inherits and does not redesign:

- **Storage**: content-addressed blobs with transactional refcounts, the publish-then-commit
  and commit-then-unlink orderings, staging in `<root>/tmp` (`design.md` §6–§8).
- **Identity encoding**: the canonical text encoding of `design.md` §5.2, frozen by golden
  vectors, with the ban on hashing `serialize()` output. A schema *constrains* what may be
  canonicalised; it is not a second encoding.
- **Derived, rebuildable indexes** with order-preserving encodings (`design.md` §7.4–§7.5).
- **Per-record codec dispatch**, so a dataset can change codec without orphaning anything.
- **An extensible meta record**, so provenance fields arrive without a migration, and
  `retain_until`, written from the cache's v1.
- **The error taxonomy** of `design.md` §13, which this layer extends (§2.7).
- **The deployment envelope**: many processes on one host, over a local filesystem.

Four premises of the original draft no longer hold, and the text below is written without
them rather than annotated:

- **The store was assumed to sit on Azure Files, a blobfuse mount or a shared AKS volume**,
  and the architecture was derived from locks being unreliable there. It does not; locks
  and `mmap` work. "A broken lock costs duplicate work, not corruption" survives as a
  property the test suite proves (§10), not as the reason for the design.
- **SQLite as the metastore, behind `storr`'s driver contract** as insurance against an
  engine that did not exist. The engine is `mdbx`, on CRAN, through the cache.
- **R6 datasets with `d$get()`.** The API is functional, like the cache's (`design.md` D1,
  D2).
- **`mdbx_estimate_range()`, `mget` and `mput`.** `mdbx` has none of them (`design.md` §15);
  §4 plans `find()` without them.

---

# 1. What this is

```r
s <- stash("~/.cache/market")

prices <- dataset(
  "prices", s,
  keys     = list(date = key_date(), exchange = key_character()),
  produce  = function(key) fetch_prices(key$date, key$exchange),
  identify = identifier(fields = "date"),
  codec    = codec_parquet()
)

ds_get(prices, date = as.Date("2026-08-29"), exchange = "XSWX")
ds_find(prices, exchange = "XSWX")
```

Identity is **declared, typed and queryable**, and **independent of the producer**. The
same logical dataset can move from an HTTP API to a database to local computation without
its key changing, and the store can be searched by key component rather than by hash,
filename or function arguments.

## 1.1 Why not something that exists

| Tool | Why it is not this |
|---|---|
| `pins` | A good store and a poor identity layer: names are strings, no key schema, no query over key components, no producer contract, no verification |
| `targets` | Identity *derived from implementation* — a dependency graph keyed by code and upstream results. Here identity is *declared by the domain*, which is what lets the producer change without invalidating anything |
| `storr` | `key(string) -> value`; stores anything under any key, with no notion of what the value represents |
| `stash_memoise()` | Keys on a function's arguments. A dataset keys on what the value *is*, so two producers of the same thing share entries |
| Dagster, Kedro, Intake, DVC, Quilt, LakeFS | They do model typed dataset identity (Dagster's `MultiPartitionsDefinition` over `(date, exchange)` is structurally this design). Every one is an orchestrator or a platform: a runtime, a DAG model, a config format and a deployment story. None is an in-process library callable from one R session with no infrastructure |

That last row is the defensible claim, and the one that survives a reviewer who knows
Dagster. Intake is the closest design and it stalled; understanding why is cheaper than
rediscovering it.

---

# 2. The contract

## 2.1 Canonicalisation under a schema

A key is a **complete assignment of values to a dataset's key schema** — total, because
the key space of a dataset is a product type (`cache-model.md` §9). Fields may declare
defaults; a field with no default and no supplied value is `dastash_key_invalid` at key
construction, never a silent `NULL`.

Each field type validates and coerces a value before the cache's canonical encoding sees
it. The encoding is the cache's; the types decide what reaches it:

| Type | Rule | Reaches the encoding as |
|---|---|---|
| `key_integer()` | `1L` and `1` agree; outside ±2⁵³ rejected unless the field is `key_integer64()` | `i:` |
| `key_integer64()` | `bit64`-backed, for instrument and account identifiers past the double mantissa | `i:` |
| `key_double(precision)` | Rejected without a declared precision, which rounds before encoding; `NaN` rejected | `f:` or `i:` |
| `key_character()` | UTF-8, NFC-normalised, case-sensitive unless declared otherwise | `s:` |
| `key_date()` | ISO-8601; the underlying double is never encoded | `d:` |
| `key_timestamp()` | UTC; `tzone` is never identity | `t:` |
| `key_enum(levels)` | The level string; unknown levels rejected at construction | `e:` |
| `key_hashed(inner)` | Validated as `inner`, stored only as its hash (§6.1) | `s:` of the digest |
| `key_factor()` | Exists only to raise `dastash_key_invalid` pointing at `key_enum()` | — |

`NA` is a legitimate value, distinct from every other value of its type (D4); it encodes
as the cache's `!` payload. Absence is an error.

The typed layer is where precision and normalisation belong, and the cache is where they
do not (`design.md` D12): a cache keyed on memoised arguments must accept `0.1` as given,
while a dataset declares what its identity means. NFC normalisation needs `utf8` or
`stringi`; which one, and whether it becomes an import of the layer, is open.

**Domain separation.** A dataset's entries live under stash keys
`<dataset>/` ‖ canon(named list of fields), so the same field values under two datasets
never collide, and every dataset is a prefix scan.

## 2.2 Production and identification

Two functions with different contracts:

```text
produce  : Key  -> Value        required for ds_get()
produce  : ()   -> Value        optional, enables discovery
identify : Value -> PartialKey  optional
```

`identify` is **partial by default**. Most producers cannot recover the full key from
the value: a request for `prices(date, exchange)` may return a frame carrying a date
column and nothing that attests to the exchange. A dataset therefore declares which
fields its identifier can attest to.

## 2.3 The verification invariant

The obvious statement, `identify(produce(key)) == key`, is false whenever `identify` is
partial, which is the normal case. The correct statement is a **consistency relation**:
every field the value can attest to must agree with the requested key; fields outside the
identifier's declared set are unconstrained.

```text
identify(produce(k))  ⊑  k

a ⊑ b   iff   for every field f present in a,  canon(a[[f]]) == canon(b[[f]])
```

Comparison is on canonical values, never raw R values, so `1L` against `1`, a timezone
difference or an unnormalised string never produces a false verdict.

Partial verification is still worth having: catching a producer that silently returned
the wrong date is most of the value. Catching one that returned the wrong exchange needs
an identifier that can see the exchange, and where none exists the design says so rather
than implying a guarantee it does not provide.

## 2.4 Discovery

Discovery is a **separate verb**, not `ds_get()` with no key:

```r
res <- ds_discover(prices)      # list(key = <key>, value = <value>)
```

Overloading `get` to mean "I do not know what I want" makes the return type depend on the
argument (`design.md` §2, rule 3). Discovery requires a **total** identifier, declared as
such:

```r
identify = identifier(fields = c("date", "exchange"), total = TRUE)
```

For a total identifier the equality holds, and is the stronger contract it looks like:

```text
identify(produce())   is a complete key
identify(produce(k))  ==  k
```

`ds_discover()` on a dataset with a partial identifier is `dastash_definition_invalid` at
definition time, not at call time. Discovery has no requested key, so `on_mismatch` does
not apply to it; its only contract is that the identifier returns a complete, valid key.

## 2.5 Mismatch policy

What happens when `identify(produce(k)) ⋢ k` is a per-dataset decision:

```r
on_mismatch = c("error", "warn", "adopt", "quarantine")
```

- **`error`** — default. Nothing is stored. Raises `dastash_identity_mismatch`.
- **`warn`** — store under the requested key, record the discrepancy in provenance.
- **`adopt`** — store under the *identified* key and return the value once; the requested
  key stays a miss, so a later `ds_get()` on it produces again. Adoption does not recurse:
  any other reading either loops or silently aliases two keys. Correct for sources that
  snap to a trading calendar or round to a business day.
- **`quarantine`** — store the blob, mark the record unreadable by `ds_get()`, expose it
  through `ds_find(status = "quarantined")`. For sources where discarding received data is
  not acceptable for audit reasons.

`adopt` is the one that will actually get used, and it must be opted into: silently
storing under a different key than requested is exactly the failure this layer exists to
prevent.

## 2.6 Value identity is not blob identity

The same semantic value serialises to different bytes across codec versions, compression
settings and attribute ordering, so content addressing deduplicates identical **bytes**,
not identical **values** (`cache-model.md` Results 11.3–11.4). Two consequences:

- Codec identity and version live in the record. They affect readability, not identity.
- A codec used by a dataset with an identifier must round-trip losslessly for the types
  that dataset produces, because `identify()` runs on a decoded value (`cache-model.md`
  Result 11.2). The cache's codecs declare `supports()`; the layer checks it at definition
  time and raises `dastash_definition_invalid` for a lossy codec on an identifier-bearing
  dataset.

## 2.7 Failure taxonomy

The cache's classes (`design.md` §13) apply unchanged — `dastash_key_invalid`,
`dastash_not_found`, `dastash_codec_error`, `dastash_blob_corrupt`, `dastash_readonly` —
and the layer adds five, each with `dastash_error` as parent:

| Class | Raised when |
|---|---|
| `dastash_producer_error` | The producer raised; wraps the original condition as `parent` |
| `dastash_identity_mismatch` | `⊑` violated under `on_mismatch = "error"` |
| `dastash_definition_invalid` | A dataset definition is inconsistent: an identifier naming fields outside the schema, `total = TRUE` on a partial field set, discovery without a total identifier, a lossy codec on an identifier-bearing dataset |
| `dastash_schema_drift` | The definition no longer matches the stored schema; carries a field-level diff |
| `dastash_lease_timeout` | A single-flight lease was not acquired within the timeout |

---

# 3. API sketch

Functional, with the dataset first, following the cache's conventions (`design.md` §2).

```r
dataset(name, stash, ..., keys, produce = NULL, identify = NULL, codec = NULL,
        on_mismatch = c("error", "warn", "adopt", "quarantine"))

ds_get(ds, ...)          # resolve: peek -> lease -> produce -> identify -> verify -> store
ds_peek(ds, ...)         # cache only; dastash_not_found on a miss
ds_has(ds, ...)          # logical
ds_put(ds, value, ...)   # store under an explicit key, verifying where an identifier exists
ds_discover(ds)          # list(key =, value =); needs a total identifier
ds_remove(ds, ...)
ds_find(ds, ...)         # data frame of entries matching key-field constraints
ds_entries(ds)           # data frame of every entry, key fields as columns

key_character()  key_integer()  key_integer64()  key_date()  key_timestamp()
key_enum(levels)  key_double(precision)  key_hashed(inner)
identifier(fields, total = FALSE)
```

`...` in the resolution verbs is the key's fields by name. `ds_find()` takes field
constraints by name — equality by value, ranges by a small constructor — and `status =`.
Whether ranges get a constructor or data-masking is open; `design.md` D11's objection to
data-masking (a query planner in disguise) applies less here, because the schema says
which fields are indexed.

---

# 4. Storage on the cache

The layer adds records and indexes to the cache's environment; it does not add a store.

```text
named database   key                                          value
datasets         <dataset>                                    definition: schema, identifier,
                                                              codec, fingerprint
fields           <dataset> 0x00 <field> 0x00 sort(v) ‖ key    empty
```

- **Entries** are ordinary cache entries under `<dataset>/…` keys (§2.1). Expiry,
  eviction, tags, blobs and refcounts are the cache's. Provenance goes into the meta
  record's spare names (§6.2).
- **`fields`** materialises each key field as an ordered index — the fibration of
  `cache-model.md` §9.3. `sort(v)` is a per-type order-preserving encoding (`enc_f64()` for
  numbers, dates and timestamps; UTF-8 for strings), distinct from the frozen canonical
  encoding: identity is frozen, ordering is rebuildable (`design.md` §7.5). An equality
  query is a prefix scan; a range query is a scan between two `sort` values, stopped
  client-side until `mdbx` has an upper bound (`design.md` §15).
- **`ds_find()` over several fields** intersects posting lists. With no `estimate_range()`,
  it scans the field whose constraint is narrowest by type (equality before range) and
  filters the rest from the key text, which the key carries. A cost model can come later;
  correctness does not depend on it.
- **The fingerprint** covers the name, the canonical schema form, the identifier's fields
  and totality, the codec name and version, and the key encoding version. A definition
  whose fingerprint differs from the stored one is `dastash_schema_drift`. The record
  stores the schema and fingerprint, never the producer closure.
- **Leases** for single-flight are the cache's v1.x lease records (`design.md` §19),
  keyed by the entry's stash key.

---

# 5. Decisions

**D1 — `identify` is partial by default; totality is declared.** Verification uses `⊑`;
discovery requires `total = TRUE` and is rejected at definition time otherwise. The
identifier's field set is part of the definition, and so of the fingerprint.

**D2 — Are entries versioned?** **Open**, and the one decision here that must be made
before the first dataset is stored. The case for revisions: re-production with a changed
producer is the normal case for a long-lived dataset, and a revision field is what lets
versioned entries, `latest` aliases and immutable datasets arrive later
(`cache-model.md` §10: monotone state is mergeable state). The cache caps retention at one
write per key, so revisions would live in the key — `<dataset>/<canon>/r<n>` — with the
latest found by a scan of the entry's prefix. The case against: a cache below that
evicts individual revisions makes "latest" a claim about what survived, not what was
written. Decide with the lease design, which touches the same records.

**D3 — `error` is the default mismatch policy**, with the four-way policy of §2.5.

**D4 — `NA` is a value; absence is an error.** `exchange = NA` means the exchange
dimension does not apply to this instance, which is a real thing in market data. Absence
means the caller forgot an argument, which should never resolve to a key. Keys stay total
and `ds_find()` stays unambiguous.

**D5 — `pins` is not a blob backend**, but the cache's v2 remote-backend interface
(`put/get/has/rm/list` by hash, `design.md` §19) is narrow enough that a pins board could
implement it. `pins` versions at the name level with its own directory layout and
metadata; content addressing wants a flat immutable namespace keyed by hash.

**D6 — Functions, not objects.** A dataset is a plain classed list holding its definition
and its stash; the verbs are `ds_*()` functions. Reverses the original draft's R6
`d$get()`, for `design.md` D1's reasons.

**D7 — `key_hashed()` is in the layer's first release.** §6.1 is a governance
requirement, and the field-type interface makes it cheap.

---

# 6. Governance

Provenance is a requirement in the target environment, not a feature row, and it
constrains the design.

## 6.1 The catalogue is a queryable index of key values

Key components are stored so they can be searched. A key field holding a client
identifier, a counterparty, a trader id or an account number therefore turns the store
into a searchable index of those values, in a file easier to copy than the data it
points at. In order of preference:

- Key schemas should not carry personal or client identifiers. Document the rule, and
  lint definitions for it if it is likely to be violated.
- Where unavoidable, `key_hashed()` stores the canonical hash and not the value. This
  forfeits `ds_find()` on that field, which is the honest trade.
- Encrypt the metadata at rest, not only the blobs.

## 6.2 Provenance

Recorded per entry from the layer's first release, because it cannot be retrofitted to a
store that already has data. The cache's meta record is a named list (`design.md` §7.3),
so these are added names, not a migration:

```text
produced_at        UTC timestamp
producer_id        dataset definition fingerprint
source             URI or descriptor supplied by the producer
host, user         where and by whom
r_version          reproducibility triage
mismatch           the discrepancy, under on_mismatch = "warn"
status             "ok" | "quarantined"
```

Codec, codec version, key encoding version and blob hash are already in the record.

## 6.3 Retention

Cache eviction and regulatory retention are different policies over the same records and
will conflict. An eviction that deletes an entry inside its retention window is a
compliance incident, not a cache miss. The cache writes `retain_until` from v1 and
enforces it in v1.x (`design.md` §9.4, §19): cull and evict refuse to cross it.

## 6.4 Encryption

Blobs are content-addressed by plaintext hash, so encryption must sit below the
addressing layer or deduplication is lost. Either the blob backend encrypts
transparently, or convergent encryption is accepted with its known leakage of "these two
entries are identical". The decision is where in the stack it goes, not which library.

---

# 7. Prior art, by subsystem

- **joblib.Memory** — take `call_and_shelve()`, a lightweight reference rather than a
  materialised result, as the model for artifact references; and its programmable
  validation callback, a better lifecycle primitive than a fixed TTL. Do not take identity
  derived from function code and arguments, which is what this layer exists to avoid.
- **requests-cache** — take the lifecycle vocabulary: fresh, expired, revalidatable,
  stale-if-error, cache-only, refresh. Express it source-independently,
  `cache_policy(max_age =, revalidate =, stale_if_error =, stale_while_revalidate =)`,
  and let an HTTP producer map it onto ETag and `Last-Modified`. The request is not the
  identity: `weather(station = "ZRH", date = d)` is stable across a changing API URL.
  `cache-model.md` §8 shows the whole vocabulary is a second deadline, not a subsystem.
- **Pooch** — the integrity-first acquisition sequence: known hash before fetching where
  one exists, download to a temporary location, verify, publish, post-process, return a
  path. It belongs in a specialised producer, plausibly a separate package.
- **fsspec** — explicitly out of scope. Range reads and protocol chaining cannot be served
  by a whole-file cache, and R's lack of an fsspec equivalent is a separate project,
  plausibly Rust's `object_store` via `savvy`. The layer consumes that abstraction when it
  exists.
- **klepto** — the precedent for configurable key transformation. It asks how an input
  maps to a cache key; this layer asks which fields define the identity of a dataset
  instance, which is what makes `ds_find(exchange = "XSWX")` possible.

---

# 8. Non-goals

Stated so they can be pointed at rather than re-litigated:

- A unified local/S3/Azure/GCS filesystem API
- Block or range caching, streaming remote file objects, protocol chaining
- A workflow engine, DAG, or dependency graph between datasets
- Distributed coordination beyond single-flight on one host
- Beating diskcache, requests-cache, Pooch, fsspec or joblib at their own subsystems

The last matters most. Matching each specialist individually produces an enormous
unfocused project. The target is: **match enough of each specialist's behaviour to make
resolution robust, and add a semantic identity layer that none of them makes central.**

> dastash's typed layer is in-process dataset resolution for R: Pooch-style integrity,
> diskcache-style persistence and joblib-style resolution, organised around typed
> semantic datasets, with remote I/O left to a lower layer.

Useful as shorthand, not as a parity claim.

---

# 9. Roadmap

**Layer v1** — the minimum coherent thing, on the cache:

```text
dataset definitions with typed key schemas; fingerprint and drift detection
key types of §2.1, including key_hashed()
the fields index and ds_find()
produce(key), identify, ⊑ verification, on_mismatch
ds_discover() for total identifiers
single-flight leases (shared with the cache's v1.x)
provenance per §6.2
the five condition classes of §2.7
```

**Layer v1.x** — lifecycle policy (`cache_policy()`, validation callbacks); artifact
references (joblib's `call_and_shelve()`); schema migration from the fingerprint;
immutable datasets.

**v2** — revisions exposed with `latest`/`current` aliases, if D2 lands them; ETag and
`Last-Modified` revalidation; post-production processors; external file registration.

**Separate packages** — an integrity-first acquisition producer (Pooch-equivalent); an
object-store abstraction (fsspec-equivalent).

---

# 10. Testing

The contract is well suited to property testing, and key generators derive from the
declared schema, which is machine-readable, so they need not be written per dataset.

```text
canon(canon(k)) == canon(k)                  per key type
canon(k1) == canon(k2)  <=>  k1 ~ k2         over a schema-generated key domain
sort(v) order == R order                     per ordered key type
identify(produce(k)) ⊑ k                     per dataset, where defined
identify(produce()) is total                 for total identifiers
ds_get(ds_put(v, k)) ~ v
```

Plus a table-driven suite over {4 policies} × {agrees, disagrees, unattestable field} ×
{partial, total identifier}, and a `callr` suite: N processes resolving one cold key
produce N identical results with leases, **and still do with leases disabled** — leases
are an optimisation against duplicate work, not a correctness mechanism
(`cache-model.md` Corollary 12.3), and the suite keeps proving it.

---

# 11. Build plan

After the cache's v1. Each stage ends with its tests green and `R CMD check` clean.

| Stage | Delivers | Freezes |
|---|---|---|
| A | Key types of §2.1, schemas, `key_hashed()`, an addendum to `inst/spec/key-encoding-v1.md` for typed fields, golden vectors per type | how typed values reach the encoding |
| B | `dataset()`, the `datasets` database, fingerprint, `dastash_schema_drift`, `dastash_definition_invalid` | the definition record |
| C | `ds_put()`, `ds_peek()`, `ds_has()`, `ds_remove()`, the `fields` index, `ds_find()`, `ds_entries()` | the field index shape |
| D | Producers, identifiers, `⊑`, `on_mismatch`, `ds_get()`, `ds_discover()`, provenance | the provenance names |
| E | Leases, shared with the cache's v1.x single-flight | the lease record |
| F | Vignette (identity and verification), README section, performance of `ds_find()` at 10³–10⁵ entries | — |

D2 is decided before stage B. Risks worth naming: **scope creep toward an orchestrator**
(§1.1's failure mode and §8's main non-goal — v1.x and v2 items are named and deferred,
not designed), and **personal identifiers in key schemas** (§6.1).
