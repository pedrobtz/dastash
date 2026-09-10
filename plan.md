# dastash — implementation plan

**Status:** plan, derived from `dastash-design.md` (design, pre-implementation)
**Target:** v1.0.0 as scoped in design §9
**Starting point:** `usethis` skeleton — empty `R/`, placeholder `DESCRIPTION`, no tests, no CI

Section references in the form §N.M and D1–D5 point at `dastash-design.md`.

**Deployment, corrected.** §5.1 and §5.2 state that the store will sit on Azure Files,
a blobfuse mount or a shared AKS volume, and derive the whole architecture from the
unreliability of locking there. That is not the target. The real one is
**multiple processes on a single host, over a local filesystem** — several R sessions,
scheduled jobs and workers sharing one store on one machine. Locking works, `mmap`
works, and the design sections that assume otherwise need amending before they mislead
the next reader.

---

# 0. Architecture

An embedded transactional store for metadata and the query index, with values as
files on disk. This is the shape design §7.1 already holds up as the bar — DiskCache's
"SQLite-backed metadata with filesystem storage for large values" — and it restores
§2.6's content addressing and D2's revisions as originally written.

```text
<root>/store.mdbx           metadata, find() index, blob refcounts, leases
<root>/data/<aa>/<hash>     content-addressed values, <aa> = first two hex of hash
<root>/tmp/                 staging for atomic rename, same device
```

**Key space inside MDBX.** Ordered keys, so every access pattern is a cursor
operation:

```text
d|<dataset>                              dataset definition, schema, fingerprint
a|<dataset>|<key_hash>|<rev>             artifact record: status, blob hash, provenance
i|<dataset>|<field>|<sort_value>|<key_hash>    index entry, empty value
b|<blob_hash>                            refcount and size
l|<dataset>|<key_hash>                   single-flight lease
```

- **Resolution** is a cursor to the end of the `a|<dataset>|<key_hash>|` prefix — the
  highest revision, in one operation.
- **`find(field = value)`** is a prefix scan of `i|…`; `find(date > x)` is a range scan
  over the same prefix. Multi-field queries intersect posting lists, ordered by
  selectivity via `mdbx_estimate_range()`.
- **Writes are transactional.** The artifact record, its index entries, the blob
  refcount and the supersede of the prior revision commit together or not at all.

**Values stay out of the database.** Large data frames would inflate the mapped file to
the size of the data; on disk they are content-addressed, so identical bytes are stored
once and the refcount makes `gc()` tractable.

## Dependency on `mdbx`

v1 targets a `mdbx` package (libmdbx, Apache-2.0) that does not exist yet. **dastash
must not block on it.** Stage 2 defines the storage layer behind storr's driver
contract — `get_object` / `set_object` by hash, `get_hash` / `set_hash` by key,
`list_keys` — and develops against a filesystem driver, with `storr::test_driver()` as
the conformance suite. Swapping in `driver_mdbx()` is then a constructor argument, and
the two projects proceed independently.

## Staging

| Stage | Goal | Depends on | Size |
|---|---|---|:--:|
| **0** | Repo foundation, condition taxonomy | — | S |
| **1** | Key types and canonical encoding | 0 | L |
| **2** | Storage layer: metastore interface, blob store | 0, 1 | L |
| **3** | Codec abstraction | 0 | M |
| **4** | Store + dataset + `put`/`peek`/`has`/`find`/`remove` | 1, 2, 3 | M |
| **5** | Producers, identification, verification, `get`/`discover` | 4 | L |
| **6** | Cross-process single-flight leases | 5 | S |
| **7** | Hardening, docs, release | all | M |

Milestones: **M1** identity frozen (end of 1) · **M2** durable writes (end of 4) ·
**M3** first `get()` (end of 5) · **M4** v1.0.0 (end of 7).

Identity comes first because `canon()` cannot change once a store exists. Stages 1, 2
and 3 are parallelisable after Stage 0. Stage 4 is the first end-to-end path. Each
stage lists what it **reserves** — written but not exposed, so v1.x needs no migration.

---

# Stage 0 — Repo foundation

- `DESCRIPTION`: real Title/Description/Authors, MIT license, `Depends: R (>= 4.1)`.
  `Imports:` rlang, R6, digest, bit64, storr. `Suggests:` testthat (>= 3.0), callr,
  withr, qs2, arrow, knitr, rmarkdown — and `mdbx` once it exists, promoted to Imports
  when it becomes the default backend.
- testthat 3rd edition; CI on ubuntu/macos/windows plus a **no-Suggests job**.
- `R/conditions.R` — `dastash_abort()` and one constructor per class in §2.7, plus
  `dastash_definition_invalid` (§11.1). The error vocabulary is fixed before any
  feature uses it.
- `lintr`, `styler`, `.Rbuildignore`, `NEWS.md`.

**Exit:** `R CMD check` clean (0/0/0); CI green on three platforms; every condition
class has a constructor and a test asserting its class chain.

---

# Stage 1 — Key types and canonical encoding

§2.1. Pure, no I/O, no dependency on any other stage, and the one thing that cannot be
revised after a store exists.

**Deliverables**

- `R/key-type.R` — a field type is a plain classed list (value semantics, not R6):
  `validate(x)`, `coerce(x)`, `canon_scalar(x) -> character(1)`,
  `sort_scalar(x) -> character(1)`, `na_sentinel`, `format()`.
- `R/key-types-*.R` — `key_character()`, `key_integer()`, `key_integer64()`,
  `key_date()`, `key_timestamp()`, `key_enum(levels)`, `key_double(precision)`,
  `key_hashed(inner)` (§6.1). `key_factor()` exists only to raise
  `dastash_key_invalid` pointing at `key_enum()`.
- `R/key-schema.R` — schema construction, defaults, field validation.
- `R/key.R` — key construction: total over the schema, defaults applied, `NA` legal and
  distinct (D4), missing and `NaN` rejected.
- `R/canon.R` — the encoding and `key_hash()`; `KEY_ENCODING_VERSION <- 1L`.
- `inst/spec/key-encoding-v1.md` — the normative grammar, versioned.
- `tests/testthat/golden/key-vectors.csv` — (schema, key, canon, hash) triples. Any
  change to the encoding fails this file. Identity is frozen by test, not convention.

**Proposed grammar, to be ratified in the spec**

```text
key      := field ("\n" field)*
field    := name "=" tag ":" payload
tag      := s | i | I | d | t | e | f | h | -
            (character, integer, integer64, date, timestamp, enum, double, hashed, NA)
payload  := percent-escaped UTF-8; "%", "=", "\n" and control characters always escaped
```

- **Fields encode in name-sorted order (C locale)**, so reordering the `keys =` list is
  not an identity change.
- Injectivity comes from the escape set: with `=` and `\n` escaped in both `name` and
  `payload`, no two distinct assignments share an encoding.
- `key_hash := sha256("dastash-key/v1\n" || dataset || "\n" || canon(k))`, hex.
  Domain-separated, so the same key under two datasets never collides.

**`canon_scalar` and `sort_scalar` are different functions.** Canon serves identity and
need not be order-preserving; ISO-8601 dates happen to sort lexically but integers do
not (`"10" < "9"`). Index entries use `sort_scalar` — zero-padded and offset-encoded for
numeric types — so MDBX range scans answer `find(date > x)` correctly. Keeping them
separate means the index encoding can change and be rebuilt, while identity cannot.

**Hashing:** `digest::digest(x, algo = "sha256", serialize = FALSE)`. §2.1's objection
is to `digest()`'s *serializing default*, not to the package; called explicitly it is
correct and avoids the libssl system dependency `openssl` would add.

**Tests.** Property tests with generators derived from the schema (§10), plus:
idempotence; injectivity over a generated key domain; `1L` and `1` identical;
out-of-mantissa integers rejected unless `key_integer64()`; `NA` distinct from every
value and from other types' `NA`; timestamps independent of `tzone`; NFC normalisation;
`key_double()` rejected without a declared precision; `sort_scalar` order matches
native R order for every ordered type.

One guard test greps `R/` for `serialize(` and for any `digest(` call lacking
`serialize = FALSE`, failing on a hit.

**Exit:** golden vectors committed; spec merged; property suite green.

---

# Stage 2 — Storage layer

**Deliverables**

- `R/metastore.R` — the interface, shaped to storr's driver contract so `driver_mdbx`,
  `driver_rds` and `driver_dbi` are interchangeable. Read `storr` (v1.2.6, imports R6
  and digest) before writing this; `storr::test_driver()` is the conformance suite.
- `R/metastore-fs.R` — the development backend, so Stages 3–7 proceed before `mdbx`
  exists.
- `R/metastore-mdbx.R` — the production backend once `mdbx` ships. One environment per
  store; the key space in §0; every write in a single transaction.
- `R/blob.R` — content-addressed values on disk. Publish is: encode to
  `<root>/tmp/<uuid>` on the **same device**, hash while streaming, `fsync`,
  `file.rename` into `data/<aa>/<hash>`, mode `0444`. Never stage in `tempdir()` — a
  cross-device rename is a copy, not a rename.
- Read-only mode raising `dastash_readonly`; hash verification on read raising
  `dastash_verification_failed`; a missing blob raising `dastash_blob_corrupt`.

**Publish order — blob first, transaction second:**

```text
encode -> tmp -> hash -> rename into data/<aa>/<hash>
                           then one MDBX txn:
                             insert a|<dataset>|<key_hash>|<rev>
                             insert i|… index entries
                             increment b|<blob_hash>
                             mark prior revision superseded
```

A crash between the two leaves an unreferenced blob — invisible, and reclaimable by
v1.x `gc()` through the refcount. The reverse order would leave a committed record
pointing at nothing. The metadata side is now atomic, so the only recoverable state is
an orphan.

**Concurrency.** Multi-process on one host, so MDBX's multi-reader/single-writer model
applies directly: readers never block, writers serialise, and no revision tie-break rule
is needed because the transaction that claims revision N+1 either commits or aborts.

**Tests:** `storr::test_driver()` against every backend; a `callr` suite of 8 processes
publishing to the same and to different keys, asserting no partial file is ever visible
under `data/`, exactly one winner per revision, refcounts consistent after the storm,
and all hashes verifying.

**Reserved:** `retain_until` (§6.3) is written but not enforced; refcounts are
maintained from v1 but `gc()` is v1.x; `revision` (D2) is stored and only the highest
live revision is exposed.

---

# Stage 3 — Codecs

- `R/codec.R` — `encode(value, path)`, `decode(path)`, `name`, `version`, `ext`.
- `codec_rds()` (default), `codec_file()` (the value *is* a path; encode moves or
  copies, decode returns a path), `codec_qs2()` and `codec_parquet()` behind Suggests,
  each raising `dastash_codec_error` with an install hint when the package is absent.
- **Decode dispatches on the codec recorded in the artifact record**, never on the
  dataset's current codec, so changing a codec cannot orphan existing artifacts.
- A machine-readable per-codec declaration of which R types round-trip losslessly, so
  Stage 4 can check it at definition time for datasets carrying an identifier (§2.6).

**Tests:** a (codec × type) round-trip matrix — atomic vectors, `NA`, attributes,
`POSIXct` with tz, `Date`, `integer64`, factors, data frames with row names, nested
lists — asserting `decode(encode(v)) ~ v` per §10.

---

# Stage 4 — Store, dataset, and the no-producer path

**M2. The first end-to-end write and read.**

- `R/store.R` (R6) — open or create a root, refuse a store whose format version is
  newer than the package, `datasets()`, `stats()`, read-only flag.
- `R/dataset.R` (R6) — validation of keys / identifier / codec / `on_mismatch`;
  registration under `d|<dataset>`; **fingerprint** over (name, canonical schema form,
  identifier fields and totality, codec name and version, key encoding version); drift
  detection raising `dastash_schema_drift` with a field-level diff. The record stores
  the *schema and fingerprint*, never the producer closure.
- Methods: `put()`, `peek()`, `has()`, `remove()`, `find()`. `get()` exists and raises
  `dastash_definition_invalid` when no producer is declared.
- **`find()`** intersects index prefix scans, ordered by selectivity, matching on
  `sort_scalar` values — so `1L` versus `1`, timezone and NFC differences never produce
  a false miss. Returns a data frame. Range predicates on ordered types work from v1,
  since the index is ordered anyway.
- **`remove()`** writes a tombstone revision and decrements the refcount in one
  transaction; the blob stays until `gc()`.

**Exit:** `store()` → `dataset()` → `put()` in one process, `peek()` / `find()` in a
fresh `callr` session. Getting-started vignette skeleton.

---

# Stage 5 — Producers, identification, verification

**M3. §2.2 through §2.5 — the part of the design that is actually new, and the stage no
storage decision touches.**

- `R/producer.R` — invoke `produce(key)`, wrap any condition in
  `dastash_producer_error` preserving the original as parent.
- `R/identifier.R` — `identifier(fields, total = FALSE)`; fields validated against the
  schema at definition time; `total = TRUE` requires the field set to equal the schema.
- `R/verify.R` — the `⊑` relation compared on **canonical values**, never raw R values.
  Policy dispatch over `error` / `warn` / `adopt` / `quarantine` (§2.5), with the
  discrepancy recorded in provenance for every non-`error` outcome. `quarantine` commits
  a record with `status = "quarantined"`, invisible to `get()` and reachable through
  `find(status = "quarantined")`.
- `d$get()` full resolution: `peek` → miss → lease → `produce` → `identify` → verify →
  encode → publish → return.
- `d$discover()` per §2.4, rejected for partial identifiers with
  `dastash_definition_invalid`.

**Two behaviours the design leaves open, decided here** (§11):

- **`adopt` does not recurse.** `get(k)` that adopts returns the produced value once and
  stores it under the identified key. The requested `k` remains a miss, so a later
  `get(k)` produces again. Any other reading either loops or silently aliases two keys.
- **`discover()` has no requested key**, so `on_mismatch` does not apply. Its only
  contract is that the identifier is total and returns a complete valid key.

**Tests:** the §10 identity properties, plus a table-driven suite over
{4 policies} × {agrees, disagrees, unattestable field} × {partial, total identifier}.

---

# Stage 6 — Cross-process single-flight

Small, now that locking is reliable and the store is transactional.

- `R/lease.R` — `l|<dataset>|<key_hash>` holding holder (host + pid + uuid),
  acquisition and expiry timestamps, claimed in a write transaction so acquisition is
  genuinely atomic. Reclamation is by expiry; PID liveness is not consulted (§5.3).
  Renewal for long-running producers. Timeout raises `dastash_lock_timeout`.
- Store option `single_flight = TRUE | FALSE`.

**Tests:** `callr`, 8 processes, cold key. With leases: exactly one production, eight
identical results. **With `single_flight = FALSE`: still eight identical results and no
corruption** — leases are an optimisation against duplicate work, not a correctness
mechanism, and the suite should keep proving it even though locking is now reliable.

---

# Stage 7 — Hardening, docs, release

- README: what the package is, the §2.3 verification contract, and the deployment
  envelope — multi-process on one host, local filesystem.
- Vignettes: Getting started · Identity and verification · Operating a shared store.
- `inst/spec/key-encoding-v1.md` linked from pkgdown; `NEWS.md`; print methods; an
  error-message pass reading every condition cold.
- Performance: `find()` latency at 1k / 10k / 100k artifacts, `get()` overhead over a
  bare `readRDS()`, and the MDBX file size against artifact count.
- CRAN readiness pass.

**Exit:** v1.0.0.

---

# 9. Dependency graph

```text
0 ──> 1 ──┬──> 2 ──┬──> 4 ──> 5 ──> 6 ──> 7
          │        │
          └──> 3 ──┘
```

---

# 10. Decisions this plan makes

| Decision | Choice | Rationale |
|---|---|---|
| Metastore | Embedded transactional store; MDBX in production, filesystem driver for development | §7.1's DiskCache shape. Ordered keys make resolution, equality and range queries all cursor operations, and one transaction covers record, index, refcount and supersede |
| Values | Content-addressed files on disk, not in the database | Keeps the mapped file proportional to metadata, not data; restores §2.6 dedup, which refcounts in a transaction now make tractable |
| Backend coupling | storr's driver contract | Proven across four backends in R, with `test_driver()` as a conformance suite; keeps v1 unblocked while `mdbx` is written |
| Identity vs sort encoding | `canon_scalar` and `sort_scalar` are separate | Identity is frozen forever; index ordering must be revisable and rebuildable |
| Object system | **R6**, for `store` and `dataset` only | The `d$get()` surface in §3 is native R6; both are stateful handles. Key types, schemas and codecs stay plain classed lists with value semantics |
| Field encoding order | Name-sorted, C locale | Reordering `keys =` must not change identity |
| Hash | SHA-256 via `digest(serialize = FALSE)` | Explicit, and avoids `openssl`'s libssl system dependency |
| Publish order | Blob, then transaction | A crash leaves an unreferenced blob, never a record pointing at nothing |
| `remove()` | Tombstone revision, refcount decrement, blob retained | History and §6 provenance; reclamation is v1.x `gc()` |
| Decode dispatch | On the recorded codec | A codec change must not orphan existing artifacts |
| `key_hashed()` | In v1 | §6.1 is a governance requirement and the field-type interface makes it cheap |

---

# 11. Departures from the design

1. **§2.7 has no class for definition-time violations**, though §2.4 requires
   `discover()` on a partial identifier to fail "at definition time" — nor for an
   identifier naming fields outside the schema, or a lossy codec on an
   identifier-bearing dataset. Adds `dastash_definition_invalid`.
2. **§5.1 and §5.2 describe the wrong deployment.** The store is not on Azure Files,
   blobfuse or a shared AKS volume; it is multi-process on a single host over a local
   filesystem. Both sections should be rewritten, since the whole "correctness must not
   depend on locking" argument is derived from the incorrect premise. The property is
   still worth keeping as a design constraint — Stage 6 tests it — but it is no longer
   the reason the architecture is shaped as it is.
3. **§5.4 chooses SQLite; this chooses MDBX.** With single-host multi-process confirmed,
   both work. MDBX wins on ordered keys — resolution, equality and range queries are all
   cursor operations against one key space — and on having no schema or migrations.
   SQLite would remain a legitimate fallback behind the same interface.
4. **`adopt` re-production is unspecified** — decided in Stage 5, needs a line in §2.5.
5. **`discover()` and `on_mismatch` do not interact** — worth stating in §2.4.
6. **§2.6's lossless-codec requirement is asserted by test but never checked** —
   Stage 3 makes per-codec type support machine-readable so Stage 4 can check it.
7. **§7 has no R comparables.** It positions against six Python libraries plus Dagster,
   Kedro and Intake, and §1 answers `pins` and `targets` — but not `storr`, which is
   the first package an R reviewer will name. The answer is the §7.1 DiskCache critique
   and it lands harder in R: storr models `key(string) -> value` and will store anything
   under any key, having no domain-level notion of what the value represents. `thor`
   (LMDB bindings, CRAN, MIT) belongs alongside it, and a "why not storr" belongs beside
   §1.1 and §1.2.

---

# 12. Risk register

| Risk | Impact | Mitigation | Stage |
|---|---|---|---|
| `mdbx` is not ready when dastash needs it | v1 blocked on an external package | Storage behind storr's driver contract; develop against the filesystem driver; MDBX is a constructor argument | 2 |
| libmdbx provenance | Upstream left GitHub in 2022; canonical home is `libmdbx.dqdkfa.ru` | Pin an amalgamation version and checksum, cite canonical URL and mirrors, declare Apache-2.0 in `inst/COPYRIGHTS` | `mdbx` |
| Canonical encoding revised after data exists | Every stored key orphaned | Golden vectors, written spec, version field — all before Stage 4 | 1 |
| `serialize()` reaching a hash path | Silent identity drift across R versions | Automated grep guard covering `serialize(` and bare `digest(` | 1 |
| Store outgrows one host | The deployment envelope is now explicit and narrow | State it in the README; remote backends are a v2 interface question, not a v1 retrofit | 7 |
| Optional codecs become de-facto required | Install friction, CRAN notes | No-Suggests CI job from Stage 0 | 0, 3 |
| Scope creep toward an orchestrator | §7.7's failure mode, §8's main non-goal | v1.x and v2 items are named and deferred, not designed | all |

---

# 13. After v1

From §9, annotated with what the design already reserves.

**v1.x** — lifecycle policy: TTL, `retain_until`, validation callbacks *(field written
from Stage 2)* · `gc()`, `prune()` and `check()`, straightforward now that refcounts are
transactional · retention-aware eviction, which must never cross `retain_until` (§6.3) ·
artifact references (§7.2) · batch `get`/`put`, which map onto MDBX's `mget`/`mput` ·
schema migration *(fingerprint exists, Stage 4)* · immutable datasets · stale-if-error.

**v2** — revisions exposed with `latest`/`current` aliases *(key space exists, Stage 2)*
· ETag and Last-Modified revalidation · stale-while-revalidate · remote blob backends,
where D5's narrow interface earns its place · post-production processors · external file
registration.

**Separate packages** — `mdbx`, a general-purpose libmdbx binding covering the full API,
built independently of dastash rather than shaped around it. dastash consumes a small
subset (env, write transactions, cursors, prefix and range scans, `mget`/`mput`,
`estimate_range`), so it can adopt the package well before the binding is complete ·
a Pooch-equivalent acquisition producer · an object-store abstraction, plausibly Rust
`object_store` via `savvy`.
