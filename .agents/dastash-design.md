# dastash — a typed artifact store for R

**Status:** design, pre-implementation
**Package name:** `dastash` (free on CRAN, PyPI and crates.io)

A library that resolves a declared, typed identity to a stored artifact, producing it
on demand when absent.

```text
Dataset × Key  ->  Artifact  ->  Blob
```

This document states the semantic contract precisely, records the decisions still
open, scopes v1, and uses prior art to set a quality bar for individual subsystems
rather than to score the design against shipped software.

---

# 0. Terminology

Fixed here because three of these words are overloaded in adjacent tooling.

| Term | Meaning in `dastash` |
|---|---|
| **Dataset** | A persistent declarative definition: name, typed key schema, codec, producer, optional identifier, policy |
| **Key** | A complete assignment of values to a dataset's key schema |
| **Artifact** | A metastore row: identity, provenance, blob reference, status |
| **Blob** | Content-addressed bytes in the blob store |
| **Producer** | `Key -> Value`, and optionally `() -> Value` |
| **Identifier** | `Value -> PartialKey` |
| **Store** | The pairing of one metastore and one blob store |

"Artifact" is internal vocabulary. The user-facing noun is **dataset**, which avoids
collision with build artifacts in CI and Nexus.

---

# 1. What this is

```r
prices <- dastash::dataset(
  "prices",
  keys = list(
    date     = key_date(),
    exchange = key_character()
  ),
  produce  = function(key) fetch_prices(key$date, key$exchange),
  identify = identifier(fields = "date"),
  codec    = codec_rds()
)

prices$get(date = as.Date("2026-08-29"), exchange = "XSWX")
prices$find(exchange = "XSWX")
```

Identity is **declared, typed and queryable**, and **independent of the producer**.
The same logical artifact can move from an HTTP API to a database to local
computation without its key changing, and the store can be searched by key component
rather than by hash, filename or function arguments.

## 1.1 Why not `pins`

`pins` gives versioned boards over local, S3 and Azure with attached metadata, and
is the first thing any R reviewer will name. It is a good store and a poor identity
layer: names are strings, there is no key schema, no query over key components, no
producer contract, no identity verification. `dastash` is the layer above it. See D5
for whether a pins board becomes a blob backend.

## 1.2 Why not `targets`

`targets` solves an adjacent and different problem: a dependency graph of
computations keyed by code and upstream results. Identity there is *derived from
implementation*. In `dastash` it is *declared by the domain*, which is what allows the
producer to change without invalidating anything.

---

# 2. The contract

This section is the design. Everything else is scope and sequencing.

## 2.1 Canonicalisation

`canon(k)` maps a key to a canonical byte encoding. Everything else rests on it, and
it is harder in R than in Python.

**Required properties.**

```text
canon(canon(k)) == canon(k)              idempotent
canon(k1) == canon(k2)  <=>  k1 ~ k2     injective over the schema domain
```

**Rules per key type.** These are decisions, not implementation details, and belong
in a versioned written specification:

| Type | Rule |
|---|---|
| `key_integer()` | `1L` and `1` canonicalise identically; values outside `[-2^53, 2^53]` rejected unless the field is declared `key_integer64()` |
| `key_integer64()` | `bit64`-backed. Exists from v1 because external instrument and account identifiers will exceed the double mantissa |
| `key_double()` | Rejected by default. Floating point equality is not an identity relation. Permitted only with a declared precision that rounds before encoding |
| `key_character()` | Converted to UTF-8, NFC-normalised, case-sensitive unless the field declares otherwise |
| `key_date()` | ISO-8601 date. The underlying double is never encoded |
| `key_timestamp()` | Normalised to UTC, ISO-8601 with offset. The `tzone` attribute is never part of identity |
| `key_enum(levels)` | Encoded as the level string; unknown levels rejected at key construction |
| `key_factor()` | Rejected. Use `key_enum()` |

**Never hash `serialize()` output.** R's serialisation is not stable across versions,
is affected by ALTREP representations, and `digest()`'s default does exactly this.
Define an explicit canonical encoding with a written grammar and a version number
recorded in the metastore. A documented text encoding is preferable to a binary one
for debuggability; `amber` is an option if a binary encoding is wanted later.

**Key completeness.** A key is always total over its schema. Fields may declare
defaults; a field with no default and no supplied value is an error at key
construction, not a silent `NULL`. See D4 for `NA`.

## 2.2 Production and identification

Two functions with different contracts:

```text
produce  : Key  -> Value        required
produce  : ()   -> Value        optional, enables discovery
identify : Value -> PartialKey  optional
```

`identify` is **partial by default**. Most producers cannot recover the full key from
the value: a request for `prices(date, exchange)` may return a frame carrying a date
column and nothing that attests to the exchange. A dataset therefore declares which
fields its identifier can attest to.

## 2.3 The verification invariant

The obvious statement is

```text
identify(produce(key)) == key
```

and it is false whenever `identify` is partial, which is the normal case. The correct
statement is a **consistency relation**: every field the value can attest to must
agree with the requested key; fields outside the identifier's declared set are
unconstrained.

```text
identify(produce(k))  ⊑  k

a ⊑ b   iff   for every field f present in a,  canon(a[[f]]) == canon(b[[f]])
```

Partial verification is still worth having. Catching a producer that silently
returned the wrong date is most of the value. Catching one that returned the wrong
exchange requires an identifier that can see the exchange, and where none exists the
design should say so rather than imply a guarantee it does not provide.

## 2.4 The discovery contract

Discovery is a **separate verb**, not `get(NULL)`:

```r
res <- prices$discover()      # list(key = <Key>, value = <Value>)
```

Overloading `get()` to mean "I do not know what I want" makes the return type depend
on the argument, which is bad in any language and worse in one with lazy evaluation
and partial matching.

Discovery requires a **total** identifier, declared as such:

```r
identify = identifier(fields = c("date", "exchange"), total = TRUE)
```

For a total identifier the original equality does hold, and is worth stating as the
stronger contract it is:

```text
identify(produce())   is a complete key
identify(produce(k))  ==  k
```

Calling `discover()` on a dataset with a partial identifier is an error at definition
time, not at call time.

## 2.5 Mismatch policy

What happens when `identify(produce(k)) ⋢ k` is a per-dataset decision:

```r
on_mismatch = c("error", "warn", "adopt", "quarantine")
```

- **`error`** — default. Nothing is stored. Raises `dastash_identity_mismatch`.
- **`warn`** — store under the requested key, record the discrepancy in provenance.
- **`adopt`** — store under the *identified* key; the requested key resolves to a
  miss. Correct for sources that snap to a trading calendar or round to a business
  day.
- **`quarantine`** — store the blob, mark the row unreadable by `get()`, expose via
  `find(status = "quarantined")`. Needed where discarding received data is not
  acceptable for audit reasons.

## 2.6 Artifact identity is not blob identity

The same semantic value serialises to different bytes across codec versions,
compression settings and attribute ordering. Content addressing therefore
deduplicates identical **bytes**, not identical **values**.

Three consequences to design for rather than discover:

- One key maps to a *sequence* of blobs over time. The metastore's primary key
  question is not deferrable. See D2.
- Codec identity and version live in blob metadata. They affect readability, not
  identity.
- A codec used by a dataset that has an identifier must round-trip losslessly for the
  types that dataset produces, because `identify()` runs on a decoded value. Assert
  this by test, per codec, per type.

## 2.7 Failure taxonomy

Conditions are part of the API. Classed, via `rlang::abort()`. Every one of these is
reachable in a normal week of operation, and callers need to distinguish "produce it
again" from "your store is broken".

| Class | Raised when |
|---|---|
| `dastash_key_invalid` | Key fails schema validation or canonicalisation |
| `dastash_not_found` | Cache-only resolution missed, or `peek()` on an absent key |
| `dastash_producer_error` | Producer raised; wraps the original condition |
| `dastash_identity_mismatch` | `⊑` violated under `on_mismatch = "error"` |
| `dastash_verification_failed` | Blob hash did not match expected or recorded hash |
| `dastash_codec_error` | Encode or decode failed |
| `dastash_lock_timeout` | Single-flight lease not acquired within timeout |
| `dastash_blob_corrupt` | Blob missing, or hash mismatch on read |
| `dastash_schema_drift` | Dataset definition no longer matches the stored schema |
| `dastash_readonly` | Write attempted against a read-only store |

---

# 3. API surface

The whole v1 public surface, for review in one place.

**Store**

```r
store <- dastash::store(path = "~/.dastash")      # metastore + blob store
store$datasets()                                 # registered definitions
store$stats()
```

**Dataset definition**

```r
d <- dastash::dataset(
  name,
  keys        = list(...),        # named key_* constructors
  produce     = function(key) ..., 
  identify    = identifier(fields = ..., total = FALSE),
  codec       = codec_rds(),
  on_mismatch = "error",
  store       = store
)
```

**Resolution**

```r
d$get(...)          # resolve; produce on miss; verify; store; return value
d$peek(...)         # cache-only; dastash_not_found on miss
d$has(...)          # logical
d$put(value, ...)   # store a value under an explicit key, verifying if possible
d$discover()        # list(key=, value=); requires a total identifier
d$remove(...)
d$find(...)         # query by key component; returns a data frame of artifacts
```

**Keys and codecs**

```r
key_character()  key_integer()  key_integer64()  key_date()
key_timestamp()  key_enum(levels)  key_double(precision)

codec_rds()  codec_qs()  codec_file()  codec_parquet()
```

Whether `dataset` is R6 or S7 is an implementation choice, not a contract. S7 gives
better printing, validation and generic dispatch; R6 gives the `d$get()` syntax
above with less ceremony. Decide once, early, since it is expensive to change after
publication.

---

# 4. Open decisions

Five decisions block implementation. Each has a recommended default.

## D1 — Is `identify` partial or total?

**Partial by default, totality declared per dataset.** Verification uses `⊑`.
Discovery requires `total = TRUE` and is rejected at definition time otherwise.
Consequence: the identifier's field set is part of the dataset definition and
therefore part of the schema fingerprint.

## D2 — Is the metastore key versioned?

**Physically yes, logically no, in v1.** Store `(dataset, key_hash, revision)` with a
monotonic revision and a `superseded_at` timestamp. Expose only single-valued `get()`
in v1, resolving to the highest live revision.

This costs one integer column now and avoids a store migration when versioned
entries, `latest` aliases and immutable datasets arrive. The alternative,
`(dataset, key_hash)` unique with overwrite, is simpler and forecloses the entire
versioning roadmap. Re-production with a changed producer is the normal case for a
long-lived dataset, so that foreclosure is not acceptable.

## D3 — What happens on identity mismatch?

**`error` by default**, with the four-way policy in §2.5. `adopt` is the one that
will actually get used, but it must be opted into, because silently storing under a
different key than requested is exactly the failure this design exists to prevent.

## D4 — Is `NA` a value or an absence in a key?

**`NA` is a legitimate value, distinct from every other value of its type. Absence is
an error.**

`exchange = NA` means the exchange dimension does not apply to this instance, which
is a real thing in market data. Absence means the caller forgot an argument, which
should never resolve to a key. This keeps keys total over the schema, and makes
`find()` unambiguous. `canon()` encodes `NA` as a distinct sentinel per type. `NaN`
is rejected outright.

## D5 — Does `pins` become the blob backend?

**No, but define the interface so it could be.**

`pins` versions at the *name* level with its own directory layout and metadata files.
Content addressing wants a flat immutable namespace keyed by hash. Layering one on
the other means fighting the version directories and carrying a second, divergent
metadata layer alongside the metastore.

Define a narrow backend interface instead:

```r
blob_backend(
  put  = function(hash, path) ...,   # atomic, idempotent
  get  = function(hash) ...,         # returns a local path
  has  = function(hash) ...,
  rm   = function(hash) ...,
  list = function(prefix) ...
)
```

Local filesystem for v1. Azure via `AzureStor` or `qak` later. A pins board stays
implementable against this interface by anyone who wants it.

---

# 5. Constraints

Specific to R and to the target deployment environment, and they change what should
be built.

## 5.1 There are no threads

Single-flight *within* a process is free: R cannot execute two resolutions
concurrently. The entire concurrency problem is **cross-process** — multiple
sessions, Spark executors, AKS pods, scheduled jobs. That is a narrower problem than
DiskCache's and should be solved with less machinery.

## 5.2 Locks may not work

The store will sit on Azure Files, a blobfuse mount, or a shared AKS volume. Advisory
locking over SMB and NFS is unreliable, and `filelock` may silently fail to provide
mutual exclusion.

**Correctness must therefore not depend on locking.** It comes from:

```text
content-addressed blobs     identical bytes are interchangeable
atomic rename on publish    a blob is present or absent, never partial
idempotent producers        re-running is wasteful, not wrong
```

Locking is then purely an optimisation preventing stampedes. A broken lock costs
duplicate work, not corruption. This is the most important architectural decision in
the document and it belongs in the README, not buried here.

The supported filesystem matrix must be explicit: which combinations are tested,
which are best-effort, which are unsupported.

## 5.3 Lease recovery

PID-based liveness checks are meaningless across containers. Use a lease with an
expiry timestamp and a holder identifier, renewed by long-running producers,
reclaimable after expiry. Document the failure mode where a producer stalls past its
lease and two processes produce concurrently, and note that §5.2 makes it survivable.

## 5.4 Metastore engine

**SQLite, not DuckDB.** The metastore workload is small transactional writes from
multiple processes, which is SQLite's design centre and DuckDB's weak point.
DuckDB's single-writer model makes it wrong here despite its role elsewhere in the
stack. The metastore file can still be attached read-only from DuckDB for analytical
queries over the catalogue, which gets the benefit without the concurrency cost.

WAL mode, a busy timeout, and a schema version table from the first commit.

---

# 6. Governance and operational risk

Provenance is a requirement in the target environment, not a feature row, and it
constrains the design.

## 6.1 The catalogue is a queryable index of key values

Key components are stored in the metastore precisely so they can be searched. A key
field holding a client identifier, a counterparty, a trader id or an account number
therefore turns the metastore into a searchable index of those values, in a file
easier to copy than the data it points at.

In order of preference:

- Key schemas should not carry personal or client identifiers. Document the rule, and
  lint dataset definitions for it if it is likely to be violated.
- Where unavoidable, provide a hashed key field type storing the canonical hash and
  not the value. This forfeits `find()` on that field, which is the honest trade.
- Encrypt the metastore at rest, not only the blobs.

## 6.2 Provenance

Recorded per artifact from v1, because retrofitting provenance to an existing store
is not possible:

```text
produced_at        UTC timestamp
producer_id        dataset definition fingerprint
source             URI or descriptor supplied by the producer
host, user         where and by whom
r_version          reproducibility triage
codec, codec_ver   readability
key_encoding_ver   canonicalisation changes
blob_hash, algo    integrity
```

## 6.3 Retention

Cache eviction and regulatory retention are different policies over the same rows and
will conflict. An LRU that deletes an artifact inside its retention window is a
compliance incident, not a cache miss. The lifecycle model must support a
`retain_until` that eviction cannot override, and `prune()`/`gc()` must refuse to
touch such rows. Cheap to design in, expensive to add later.

## 6.4 Encryption

Blobs are content-addressed by plaintext hash, so encryption must sit below the
addressing layer or deduplication is lost. Either encrypt the blob backend
transparently, or accept convergent encryption and its known leakage of "these two
artifacts are identical". The decision is where in the stack it goes, not which
library.

---

# 7. Prior art

Organised by subsystem, because that is how the lessons apply.

## 7.1 Local cache engine — DiskCache

Sets the bar for SQLite-backed metadata with filesystem storage for large values,
cross-process safety, transactions, expiry, size limits, several eviction policies,
tag-based eviction, sharding, statistics and stampede prevention.

**Take:** the SQLite schema shape, WAL and busy-timeout configuration, the eviction
policy set, size accounting, the stampede-prevention recipe.

**Do not take:** the public abstraction. DiskCache models `key -> value` and will
happily store the wrong data under a key, having no domain-level way to know what the
value represents. That is the gap `dastash` exists to close. Note also that DiskCache
assumes a POSIX filesystem with working locks; see §5.2.

## 7.2 Memoization and result references — joblib.Memory

Sets the bar for persistent memoization: argument hashing, large-array handling,
validation callbacks, cache reduction by size and age, function-code change
awareness, and `call_and_shelve()` returning a lightweight reference rather than
materialising the result.

**Take:** `call_and_shelve()` as the model for `artifact_ref`, and the programmable
validation callback, which is a better lifecycle primitive than a fixed TTL.

**Do not take:** identity derived from function code and arguments. `dastash`
deliberately decouples identity from producer implementation, which is the point of
§2.2. Joblib is the right reference if computation memoization later becomes a
specialisation, and the wrong model for the core.

## 7.3 Freshness and revalidation — requests-cache

Sets the bar for cache lifecycle semantics: `Cache-Control`, per-URL and per-request
expiration, conditional requests, cache-only mode, refresh, `stale_if_error`,
`stale_while_revalidate`.

**Take:** the state model. A cached entry is not simply fresh or expired:

```text
fresh            usable without contact
expired          must revalidate
revalidatable    cheap conditional check available
stale-if-error   usable when production fails
cache-only       network forbidden
refresh          bypass cache, replace entry
```

That vocabulary is source-independent and belongs in the lifecycle policy.

**Do not take:** HTTP fields in the generic API. The request is not the identity.
`weather(station = "ZRH", date = d)` is stable across a changing API URL, and the
producer may be HTTP, SQL, local computation, object storage, or another artifact.
Express policy as

```r
cache_policy(
  max_age                = ...,
  revalidate             = TRUE,
  stale_if_error         = ...,
  stale_while_revalidate = ...
)
```

and let a specific producer map that onto ETag and `Last-Modified`.

## 7.4 Reproducible acquisition — Pooch

Sets the bar for integrity-first remote file acquisition: logical filename, URL, known
content hash, download to temporary location, verify, publish, post-process, return
local path, plus versioned registries and processors.

**Take:** the download sequence verbatim, and the insistence on a known hash *before*
fetching where one is available. Also mirrors, retries and recorded source
provenance.

**Do not take:** it into the core. This belongs in a specialised producer, plausibly a
separate package. Pooch also starts from a known registry identity, where `dastash` can
infer identity from returned content.

## 7.5 Remote and partial file access — fsspec

Sets the bar for a unified filesystem layer: many backends, serialisable filesystem
objects, `OpenFile` references, buffered and range reads, whole-file and block
caching, URL chaining such as `zip::simplecache::https://...`, write caching,
filesystem transactions.

**Explicitly out of scope.** Range reads over Parquet and columnar formats cannot be
served by a whole-file artifact cache, and protocol chaining should not be reinvented
inside a dataset API. R's lack of an fsspec equivalent is a real ecosystem gap and a
separate project, plausibly backed by Rust's `object_store` via `savvy`. `dastash`
should consume that abstraction when it exists.

```text
dastash: dataset / artifact resolution
        |
        +---- Metastore (SQLite)
        |
        `---- BlobStore
                |
        object-store abstraction
                |
    local | S3 | Azure | GCS
```

## 7.6 Key mapping — klepto

Explores configurable key transformation and multiple archive backends: raw versus
hashed keys, serialised mappings, directory and database archives.

**Take:** the precedent, if pluggable canonicalisation is ever exposed.

**Distinction:** klepto asks how an input should be mapped to a cache key. `dastash`
asks what fields define the semantic identity of a dataset instance. The schema
describes the domain, which is what makes `find(exchange = "XSWX")` possible.

## 7.7 Typed dataset identity — the actual comparables

It is tempting to claim no tool centrally models `Dataset × TypedKey`. That is only
true of caching libraries. These already model it:

| Tool | What it already does |
|---|---|
| **Dagster** | Software-defined assets with `MultiPartitionsDefinition` over `(date, exchange)`; IO managers are codec plus blob store; materialisation records are the metastore. Structurally the same design |
| **Kedro** | `DataCatalog` with declarative, parameterised dataset definitions and namespaces |
| **Intake** | Catalogs with typed user parameters, called as `cat.prices(date=..., exchange=...)`. Almost this exact API |
| **DVC** | Content-addressed cache, remote blob storage, data versioning |
| **Quilt / LakeFS** | Versioned logical entries with aliases |

**The defensible claim is narrower and more useful:** every existing implementation of
typed dataset identity is an orchestrator or a platform. Each requires adopting a
runtime, a DAG model, a config format and a deployment story. None is an in-process
library callable from a single R session with no infrastructure.

That is the gap, and stating it that way survives contact with a reviewer who knows
Dagster. It also says what `dastash` must avoid becoming.

Intake is worth studying for the opposite reason: it is the closest existing design
and it stalled. Understanding why is cheaper than rediscovering it.

---

# 8. Non-goals

Stated so they can be pointed at rather than re-litigated:

- A unified local/S3/Azure/GCS filesystem API
- Block or range caching, streaming remote file objects, protocol chaining
- A workflow engine, DAG, or dependency graph between datasets
- General function memoization as the primary abstraction
- Distributed coordination beyond single-flight over a shared filesystem
- Beating DiskCache, requests-cache, Pooch, fsspec or joblib at their own subsystems

The last matters most. Matching each specialist individually produces an enormous
unfocused project. The target is: **match enough of each specialist's behaviour to
make artifact resolution robust, and add a semantic identity layer that none of them
makes central.**

---

# 9. Roadmap

## v1 — the minimum coherent thing

```text
dataset definitions with typed key schema
canonical key encoding, specified and versioned
SQLite metastore with schema version table
filesystem blob store, content-addressed, atomic publish
codec abstraction with an RDS default
get / peek / has / put / remove / find
produce(key)
discover() for datasets with total identifiers
identity verification with on_mismatch policy
per-key single-flight leases, correctness independent of them
provenance columns per §6.2
classed error taxonomy per §2.7
```

Explicitly **not** in v1: TTL, eviction, size limits, `gc()`, `check()`, artifact
references, HTTP producers, revalidation, batch operations.

The metastore is in v1 because `find()` over key components and `gc()` both need an
index, and a filesystem-scan version would be discarded immediately.

This is already differentiated. Nothing in R offers typed queryable dataset identity
with producer decoupling and verification.

## v1.x — close the practical gaps

```text
lifecycle policy: TTL, retain_until, programmable validation
prune(), gc(), check() with repair
LRU / max-size / max-entries eviction, retention-aware
artifact references (joblib call_and_shelve model)
batch get / put
dataset schema fingerprint and migration path
immutable dataset mode
stale-if-error
```

## v2 and later

```text
revisions exposed in the API, latest / current aliases
ETag and Last-Modified revalidation
stale-while-revalidate
remote blob backends (Azure first)
post-production processors
external file registration
sharded metastore
```

## Separate packages

```text
remote acquisition producer   Pooch-equivalent, integrity-first downloads
object store abstraction      fsspec-equivalent, plausibly Rust object_store
```

---

# 10. Testing

The contract in §2 is unusually well suited to property testing, and the invariants
should be executable rather than prose.

**Properties.**

```text
canon(canon(k)) == canon(k)
canon(k1) == canon(k2)  <=>  k1 ~ k2         over a generated key domain
decode(encode(v)) ~ v                        per codec, per supported type
identify(produce(k)) ⊑ k                     per dataset, where defined
identify(produce()) is total                 for total identifiers
get(put(v, k)) ~ v
put is idempotent under identical bytes
```

Key generators derive from the declared schema, which is machine-readable, so they
need not be written per dataset.

**Concurrency.** Spawn real R sessions with `callr` and assert linearisability of
concurrent `get()` on a cold key: N processes, one production, N identical results,
no partial blobs. Run the same suite with locking disabled to verify the §5.2 claim
that correctness survives lock failure.

**Filesystem matrix.** The above against tmpfs, ext4, an SMB mount and a blobfuse
mount. Record which combinations pass in the README.

---

# Appendix A — What the specialists do today

Design targets deliberately excluded; this is about the state of the Python ecosystem
and nothing else.

```text
++  strong / central     +  supported     ~  partial or indirect     -  absent
```

| Capability | DiskCache | joblib | requests-cache | Pooch | fsspec | klepto |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| Persistent local cache | ++ | ++ | ++ | ++ | + | ++ |
| Generic key/value storage | ++ | - | - | - | ~ | ++ |
| Files first-class | + | ~ | - | ++ | ++ | + |
| Structured keys | ~ | arguments | HTTP request | filenames | paths | + |
| Typed key schema | - | - | - | - | - | - |
| Query by key component | - | - | ~ | - | ~ | ~ |
| Resolve on miss | ~ | ++ | ++ | ++ | ++ | ~ |
| Identity inference from value | - | - | - | - | - | - |
| Content-addressed blobs | - | hashed calls | backend | verification | - | ~ |
| Searchable catalogue | + tags | per call | ++ | registry | FS | ~ |
| Freshness / revalidation | + | ~ | ++ | - | + | + |
| Eviction and size limits | ++ | + | backend | - | block LRU | ~ |
| Cross-process safety | ++ | ~ | backend | ~ | varies | backend |
| Single-flight | ++ | - | ~ | - | - | - |
| Transactions | ++ | - | backend | - | + | backend |
| Integrity check / repair | ++ | - | + | checksum | - | ~ |
| Reference without loading | + | ++ | + | path | ++ | ~ |
| Range / partial reads | - | - | - | - | ++ | - |
| Unified remote FS | - | - | - | - | ++ | - |

The freshness family (TTL, stale-if-error, stale-while-revalidate, per-entry policy)
is one subsystem and is collapsed into one row here. Splitting it inflates apparent
breadth fourfold.

# Appendix B — Requirements by priority

| Requirement | Priority | Benchmark |
|---|---|---|
| Typed key schema and canonicalisation | v1 | none exists |
| Metastore with queryable key components | v1 | Dagster, Kedro |
| Content-addressed blobs, atomic publish | v1 | DVC, Pooch |
| Identity verification | v1 | none exists |
| Discovery via total identifier | v1 | none exists |
| Cross-process single-flight | v1 | DiskCache |
| Provenance | v1 | Pooch, Dagster |
| Error taxonomy | v1 | none |
| Lifecycle policy states | v1.x | requests-cache |
| Eviction, size limits, gc | v1.x | DiskCache |
| Artifact references | v1.x | joblib |
| Schema migration | v1.x | none |
| Versioned entries and aliases | v2 | Quilt, LakeFS |
| HTTP revalidation | v2 | requests-cache |
| Reproducible download producer | separate pkg | Pooch |
| Remote filesystem, range reads | separate pkg | fsspec |

# Appendix C — Positioning

> `dastash` is an in-process artifact store for R: Pooch-style integrity, DiskCache-style
> persistence and joblib-style resolution, organised around typed semantic datasets,
> with remote I/O left to a lower layer.

Useful as shorthand, not as a parity claim. Each named system is more mature in its
own subsystem and will remain so. The claim is about composition and about the
identity model.
