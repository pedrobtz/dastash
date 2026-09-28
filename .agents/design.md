# dastash — a disk cache for R, on mdbx

**Status:** design, pre-implementation
**Engine:** `mdbx` 0.1.0 (bindings to libmdbx; submitted to CRAN, not yet accepted)
**Model:** Python's [`diskcache`](https://github.com/grantjenks/python-diskcache), with
[`polars-diskcache`](https://github.com/lmmx/polars-diskcache)'s file-backed frames

```text
key -> (metadata in mdbx) -> value inline, or a file on disk
```

`dastash` is a persistent, cross-process disk cache for R. Small values live inside a
single transactional key-value file; large ones are written to content-addressed files
and the store keeps a pointer — which is how a data frame becomes a Parquet file that
`arrow` and `duckdb` can read without R ever materialising it.

---

# 0. Relationship to the other documents

Three documents now exist and they do not describe the same package.

| Document | What it is | Status |
|---|---|---|
| `dastash-design.md` | A *typed artifact store*: declared key schemas, producers, identifiers, verification | Deferred. See §17 |
| `plan.md` | The staged implementation plan for that store | Deferred with it |
| **`design.md`** (this) | The **cache**: `key -> value` on mdbx, DiskCache's API surface | **Current** |

This is a narrowing, and a deliberate one. The typed layer in `dastash-design.md` sits
*above* a cache and cannot be built before one exists; every one of its storage
concerns — atomic publish, content addressing, refcounts, ordered indexes, a classed
error taxonomy — is a concern of this document. §17 records exactly which of its
decisions survive, so re-reading it later is cheap rather than confusing.

**What carries over unchanged** from the earlier work, because it was right and is
independent of the layer: the publish ordering (§7), the ban on hashing `serialize()`
output for identity (§4), the separation of *identity* encoding from *sort* encoding
(§4, §5), staging in `<root>/tmp` rather than `tempdir()` (§7), and the classed error
taxonomy (§12).

**What is corrected.** `dastash-design.md` §5.1–§5.2 derive an entire lock-independent
architecture from the store sitting on Azure Files or a blobfuse mount. That is not the
deployment. The target is **multiple processes on a single host over a local
filesystem** — several R sessions, scheduled jobs and workers sharing one directory on
one machine. libmdbx needs a working `mmap` and a working lock file, and gets both.
`plan.md` §11.2 already said this; it is now load-bearing rather than an aside.

---

# 1. What this is

```r
s <- dastash::stash("~/.cache/prices")

s$set("XSWX/2026-08-29", quotes, expire = 3600, tag = "XSWX")
s$get("XSWX/2026-08-29")

s$set("trades", big_frame, codec = codec_parquet())
arrow::open_dataset(s$path("trades"))      # the file, not the value

s$evict(tag = "XSWX")
s$cull()
```

DiskCache's proposition, in R: a cache that outlives the session, is safe to share
between processes, bounds its own size, expires and evicts on a policy you choose, and
does not fall over when the values are larger than memory is comfortable with. Nothing
in R offers that today — §1.1 and §1.2 say why the two obvious candidates do not.

## 1.1 Why not `cachem`

`cachem` is the interface Shiny and `memoise` use, and `cachem::cache_disk()` is a real
disk cache: one RDS file per key, an in-memory index, LRU and max-size pruning. It is
the right shape for a session-scoped memoisation cache and the wrong shape for a shared
persistent store: there are no transactions, pruning walks the directory, there is no
expiry index, tags do not exist, and concurrent writers coordinate by hoping. Its own
documentation says the disk cache is not designed for multiple processes.

**dastash should be usable through `cachem`'s interface anyway.** `as_cachem(s)` wraps a
stash in `$get/$set/$exists/$remove/$reset/$keys` so `memoise` and Shiny can use it
without knowing what it is. That adapter is cheap and it is how the package reaches
existing users — the same role `storr`'s driver contract played in `plan.md`.

## 1.2 Why not `storr`

`storr` is the closest existing R package: content-addressed values, pluggable drivers
(RDS, DBI, `thor`/LMDB, environment), a stable `get`/`set`/`list` contract. What it does
not have is anything a *cache* needs — no expiry, no size limit, no eviction, no tags,
no statistics, no accounting. It is a store, and it is honest about being one.

The distinction matters because it decides what to build. `storr` answers "where do I
put this value and how do I get it back". `diskcache` answers "how do I keep this
directory under a gigabyte, discard what has gone stale, and survive eight processes
doing it at once". Those are different problems and dastash is solving the second.

`thor` (LMDB bindings, CRAN, MIT) is the other name a reviewer will raise. It is a
binding, not a cache, and libmdbx is LMDB's maintained descendant.

## 1.3 What changes because the engine is not SQLite

DiskCache asks SQLite for one table and six indexes, none of which needs a join, a query
planner, or SQL. It needs **sorted keys, bounded ordered scans, and atomic multi-step
writes**. mdbx provides those three directly.

| DiskCache on SQLite | dastash on mdbx |
|---|---|
| `Cache(key) -> value` | named database `values`, key → payload |
| the metadata columns | named database `meta`, key → one record |
| `INDEX (expire_time)` | named database `expiry`, key `<enc(when)><key>` |
| `INDEX (access_time)` | named database `accessed`, same shape |
| `INDEX (store_time)` | named database `stored`, same shape |
| `INDEX (tag, rowid)` | named database `tags`, key `<tag>\0<key>` |
| `ORDER BY x LIMIT n` | `mdbx_keys(db = x, limit = n)` |
| `WHERE x > ?` | `mdbx_keys(db = x, start = k)` |
| `ORDER BY x DESC LIMIT 1` | `mdbx_keys(db = x, limit = 1, reverse = TRUE)` |
| `rowid INTEGER PRIMARY KEY` | `mdbx_dbi_sequence()` |
| `BEGIN … COMMIT` | `mdbx_with_write()` |
| `filename TEXT` escape hatch | `<root>/blobs/<aa>/<hash>` |

What genuinely gets harder is that **every ordering decision moves into the key
encoding**. SQLite knows `expire_time` is a number; mdbx knows only bytes. §5 is that
problem and it is the one place in this design where a mistake is silent.

---

# 2. Scope

**v1 — the cache.**

```text
stash(dir) with persisted configuration
canonical key encoding, specified and versioned
mdbx metadata + ordered indexes, one transaction per mutation
inline values below a threshold, content-addressed files above it
codec abstraction: rds default, raw, file, qs2, parquet
set / get / add / pop / delete / touch / has / keys / info
incr / decr as atomic counters
expire / evict(tag) / cull / clear
size accounting, size_limit, eviction policies
statistics, volume(), check(repair =)
transact(), memoise()
classed error taxonomy
cachem adapter
```

**Explicitly not in v1:** fanout sharding, single-flight leases, namespaces/subcaches,
`Deque` and `Index` recipes, remote blob backends, the typed dataset layer. Each is
named in §16 with what v1 must already store for it to arrive without a migration.

---

# 3. On-disk layout

```text
<root>/cache.mdbx           the environment: metadata and every index
<root>/cache.mdbx-lck       libmdbx's lock file
<root>/blobs/<aa>/<hash>[.<ext>]   values above the inline threshold
<root>/tmp/<pid>-<n>        staging, same device, for atomic rename
```

The environment is opened with `subdir = FALSE`, so it is two files rather than a
directory. `blobs/` is sharded on the first two hex characters of the hash: 256
directories, which keeps any one of them tractable to `list.files()` during `check()`.

## 3.1 Named databases

`max_dbs = 16`, leaving room. Databases are created **on demand from the configuration**
— a stash with `eviction = "least-recently-stored"` never opens `accessed`, and one
that never uses a tag never opens `tags`. Every index is a per-write cost, so an index
nothing reads should not exist.

| Database | Key | Value | Present when |
|---|---|---|---|
| `meta` | stored key | serialized record (§3.2) | always |
| `values` | stored key | payload bytes | always |
| `expiry` | `enc_f64(expire) ‖ key` | empty | always |
| `stored` | `enc_f64(store_time) ‖ key` | empty | `eviction != "none"` |
| `accessed` | `enc_f64(access_time) ‖ key` | empty | LRU eviction |
| `hits` | `enc_u64(count) ‖ key` | empty | LFU eviction |
| `tags` | `tag ‖ 0x00 ‖ key` | empty | tags in use |
| `blobs` | `hash` | serialized `{refs, bytes, ext}` | always |

An index entry is `<8 fixed bytes><the key>` rather than just the ordinal, for two
reasons: entries must be unique, since two records can share a millisecond; and having
the key inside the index means expiry and eviction never need a second lookup to learn
what to delete.

Store-level records live in the **unnamed main database**, which is why nothing else
does:

| Key | Value |
|---|---|
| `format` | `{format_version, key_encoding_version, created_at}` |
| `config` | the persisted settings of §8.1 |
| `counters` | `{count, bytes_inline, bytes_blob, hits, misses, evictions, expired}` |

## 3.2 The meta record

One serialized record per key. It is read on every `get()`, so it stays small and the
payload is deliberately *not* in it — a scan of `meta` during `cull()` should not drag
value bytes through the page cache.

```text
stored        double   store time, epoch seconds UTC
expire        double   deadline, Inf for "never"
accessed      double   last read, as last flushed (§9.3)
hits          double   read count, as last flushed
bytes         double   encoded size
codec         string   the codec that wrote it, and its version
tag           string   or absent
blob          string   content hash, absent when the value is inline
canon         string   the full canonical key, only when the key was digested (§4)
```

**`codec` is recorded per record and decode dispatches on it**, never on the stash's
current codec. Changing a stash's default codec must not orphan what is already stored.

## 3.3 Indexes are derived; metadata is not

Every index database is a projection of `meta` and can be dropped and rebuilt from it.
That is what makes `check(repair = TRUE)` possible at all, and it is why the *index*
encodings of §5 may be revised in a later version while the *key* encoding of §4 may
not. It is the same split `plan.md` drew between `canon_scalar` and `sort_scalar`, and
it survives the change of layer intact.

---

# 4. Keys

A key is bytes. Three ways to get there.

**A string is its UTF-8 bytes.** `s$set("XSWX/2026-08-29", x)` stores under exactly
those bytes, which makes prefix scans over a `"ns/…"` convention work for free
(§8.4). Strings are NFC-normalised first, so the same text is the same key whatever
encoding the R string carried.

**A raw vector is itself**, for callers who have already encoded something.

**Anything else is canonicalised** by `key_canon()` into a documented text encoding,
then used as the key. The encoding is the one specified in
`inst/spec/key-encoding-v1.md`, versioned by `KEY_ENCODING_VERSION`, and frozen by
golden vectors in `tests/testthat/golden/`.

```text
key      := field ("\n" field)*                  # for a named list
field    := name "=" tag ":" payload
tag      := s | i | I | d | t | l | e | -         # chr, int, int64, Date, POSIXct,
                                                 # lgl, enum/other, NA
payload  := percent-escaped UTF-8; "%", "=", "\n" and controls always escaped
```

Fields encode in **name-sorted order (C locale)**, so reordering a list is not an
identity change. `1L` and `1` encode identically. `Date` is ISO-8601 and the underlying
double is never encoded. `POSIXct` is normalised to UTC with an offset, so `tzone` is
never part of identity. `NA` is a distinct sentinel per type; `NaN` is rejected.
`double` is rejected without a declared precision, because floating-point equality is
not an identity relation.

**Never hash `serialize()` output, and never call `digest()` without
`serialize = FALSE`.** R's serialisation is unstable across versions and ALTREP
representations, and a cache that outlives an R upgrade would silently lose every key.
A test greps `R/` for both and fails on a hit. This is the single invariant from the
earlier design that most deserves to survive, because the cost of getting it wrong is
paid long after the mistake.

## 4.1 The length limit, and why it is a constant

libmdbx bounds key size by page size: `mdbx_limits()$keysize_max` is **2022 bytes on a
4 KiB page and 8166 on a 16 KiB page**. Deriving a limit from the running machine would
produce a store written on macOS that cannot be read on Linux.

So the limit is a constant, chosen to fit the smallest page size with room for every
index prefix:

```text
KEY_MAX  = 512 bytes    encoded key
TAG_MAX  = 256 bytes

expiry/stored/accessed entry :   8 + 512          =  520  <= 2022
tags entry                   : 256 + 1 + 512      =  769  <= 2022
```

A key whose encoding exceeds `KEY_MAX` is stored as `"#" ‖ sha256hex(canon)` — 65 bytes
— and the full `canon` is kept in its meta record, so `keys()` and `info()` still report
the real key. Digesting is a storage detail, not an identity one: the canonical encoding
is still what determines equality.

---

# 5. Ordered encodings

mdbx sorts keys as unsigned bytes, shortest-first on a tie. An index over a number
therefore has to encode it so that **byte order is numeric order**. This is the whole
difference between an index that works and one that quietly returns the wrong rows.

**Counters** — `enc_u64(n)`: eight big-endian bytes. Nothing subtle.

**Times and any signed quantity** — `enc_f64(x)`:

```text
bits <- IEEE-754 double of x, big-endian
if (sign bit set)   bits <- bitwNot(bits)        # negatives: invert every bit
else                bits[1] <- bits[1] | 0x80    # non-negatives: set the sign bit
```

Big-endian IEEE-754 alone is **not** order-preserving: `-1` has its high bit set and
would sort above every positive number, and negatives sort in reverse among themselves.
The transform above fixes both, and inverts cleanly for decoding.

The draft in `mdbx`'s `cache.Rmd` vignette uses plain big-endian bytes, which is correct
there only because every value it encodes is a positive epoch time. This design encodes
signed quantities too, so it needs the full transform.

Two properties fall out and are worth keeping:

- **`Inf` sorts last**, so `expire = Inf` means "never expires" with no special case in
  the expiry scan.
- **`NaN` has no meaningful position** and is rejected at the boundary, never encoded.

The property test is one line and belongs in the suite from the first commit:
`identical(order(vapply(x, enc_hex, "")), order(x))` over a generated vector spanning
negatives, zero, subnormals, large magnitudes and both infinities.

---

# 6. Values, blobs and codecs

## 6.1 Inline or file

A value smaller than `inline_max` (default 32 KiB, matching DiskCache) is stored in the
`values` database. Anything larger is written as a file and the record keeps a pointer.
Two codecs are always file-backed regardless of size, because their point is the file:
`codec_file()` and `codec_parquet()`.

Files are **content-addressed**: `blobs/<aa>/<hash>` where `hash` is SHA-256 of the
encoded bytes, `<aa>` its first two hex characters. Identical bytes are stored once, and
the `blobs` database holds a refcount so deletion is safe. Content addressing is about
*bytes*, not values — the same data frame written by two codec versions is two blobs,
and that is correct, since the hash exists to say whether a file is the file the record
means.

## 6.2 Codecs

```r
codec_rds()       # the default. serialize(), any R object, lossless
codec_raw()       # raw vectors and single strings, stored as-is, no serialisation
codec_file()      # the value IS a path: encode moves or copies, decode returns a path
codec_qs2()       # Suggests: qs2. faster and smaller than rds for large objects
codec_parquet()   # Suggests: arrow or nanoparquet. the polars-diskcache case
```

A codec provides `encode(value, path)`, `decode(path)`, `name`, `version`, `ext`, and a
machine-readable declaration of which R types it round-trips losslessly. Optional codecs
live in `Suggests` and raise `dastash_codec_error` with an install hint when absent,
verified by a no-Suggests CI job.

`codec_auto()` is the default and dispatches on the value: raw and length-1 character
to `codec_raw()`, everything else to `codec_rds()`. **It never selects a lossy codec.**
Parquet loses row names, changes some attributes, and rejects list columns; choosing it
silently for an arbitrary data frame would break the round-trip property. It is opted
into, per call or per stash.

## 6.3 The Parquet path

This is `polars-diskcache`'s arrangement and it is the reason to have `path()` at all:

```r
s$set("trades", df, codec = codec_parquet())

s$get("trades")            # a data.frame, decoded through arrow
s$path("trades")           # "<root>/blobs/9f/9fbc….parquet" — nothing decoded
arrow::open_dataset(s$path("trades"))
DBI::dbGetQuery(con, "select * from read_parquet(?)", list(s$path("trades")))
```

`path()` hands out the blob path and touches the record's access time; the value never
enters R. The returned path is stable while the entry lives, and mode `0444` means a
consumer cannot corrupt it. It is invalidated by `delete()`, `cull()` or `clear()` — a
caller holding a path across an eviction is holding a path to a deleted file, and the
documentation says so rather than pretending otherwise.

---

# 7. The two orderings that must not be got wrong

The store is transactional. The filesystem is not. Every correctness argument in this
design is about the seam between them, and there are exactly two rules.

**Writing: blob first, commit second.**

```text
encode -> <root>/tmp/<pid>-<n>  (same device)
       -> hash while writing
       -> fsync
       -> file.rename into blobs/<aa>/<hash>, mode 0444
                     then one write transaction:
                       put meta record
                       put value (inline) or nothing (blob)
                       put expiry / stored / accessed / tags entries
                       increment blobs refcount
                       update counters
```

A crash between the two leaves an **unreferenced blob**: invisible, harmless,
reclaimable by `check(repair = TRUE)`. The reverse order leaves a committed record
pointing at a file that does not exist, which is data loss. Staging must be in
`<root>/tmp` and not `tempdir()`, because a cross-device rename is a copy and is not
atomic.

**Deleting: commit first, unlink second.**

```text
one write transaction:
  read meta -> learn expire, accessed, tag, blob
  delete meta, value, and every index entry
  decrement blobs refcount; collect the path if it reached zero
  update counters
                     then, after mdbx_txn_commit() returns:
                       unlink the collected paths
```

The `cache.Rmd` vignette gets this deliberately wrong and explains why: unlinking inside
the transaction means a later failure rolls the metadata back to an entry whose file has
already gone. Orphans are recoverable, dangling references are not. The paths are
collected during the transaction and unlinked after it commits, and if the process dies
in between the orphan is collected later.

This is why the refcount is in the same transaction as the record. Without it, "is
anyone else still using this file" is not a question that can be answered atomically.

---

# 8. API

## 8.1 Opening

```r
s <- dastash::stash(
  dir,
  size_limit    = 1024^3,
  eviction      = c("least-recently-stored", "least-recently-used",
                    "least-frequently-used", "none"),
  cull_limit    = 10,
  inline_max    = 32 * 1024,
  codec         = codec_auto(),
  durability    = c("safe", "fast", "unsafe"),
  map_size      = 1024^3,
  statistics    = FALSE,
  touch_on_read = c("batched", "always", "never"),
  timeout       = 60,
  readonly      = FALSE
)
```

Settings split into two kinds, and the split is not cosmetic:

- **Store-level**, persisted in the `config` record and shared by every process:
  `size_limit`, `eviction`, `inline_max`, `codec`. The first process to create the store
  fixes them. A later process that passes a *different* explicit value raises
  `dastash_config_conflict`; one that passes nothing adopts what is there. Two processes
  disagreeing about `inline_max` would produce a store where neither can predict where a
  value lives.
- **Per-handle**: `map_size`, `statistics`, `touch_on_read`, `timeout`, `readonly`,
  `cull_limit`. These affect only this session.

`durability` is neither, and libmdbx says so: sync flags are properties of the
environment *as currently open*, and a process joining an already-open environment
inherits them. dastash opens with `ACCEDE` and reports the effective mode from
`stats()`, rather than pretending the argument won.

## 8.2 The surface

```r
# read
s$get(key, default = NULL, codec = NULL)
s$path(key)                             # blob path, nothing decoded
s$has(key)                              # logical; expired counts as absent
s$info(key)                             # the meta record, or NULL
s[[key]]                                # get, but dastash_not_found on a miss

# write
s$set(key, value, expire = NULL, tag = NULL, codec = NULL)
s$add(key, value, ...)                  # set only if absent; TRUE if it landed
s$touch(key, expire = NULL)             # extend a deadline without rewriting
s[[key]] <- value

# remove
s$delete(key)                           # TRUE if something went
s$pop(key, default = NULL)              # get and delete, atomically

# counters
s$incr(key, delta = 1L, default = 0L)   # atomic, integer64
s$decr(key, delta = 1L, default = 0L)

# enumerate
s$keys(prefix = NULL, start = NULL, limit = NULL)
s$size()                                # number of live entries

# maintenance
s$expire(limit = NULL)                  # delete what is past its deadline
s$evict(tag)                            # delete every entry with this tag
s$cull()                                # expire, then evict until under size_limit
s$clear()                               # empty it
s$check(repair = FALSE, hash = FALSE)   # integrity report
s$flush()                               # write out the read journal (§9.3)

# accounting
s$volume()                              # bytes on disk
s$stats()                               # hits, misses, count, evictions, expired

# composition
s$transact(fun)                         # one write transaction over several calls
s$memoise(fun, expire = NULL, tag = NULL, version = NULL)
s$close()

as_cachem(s)                            # the cachem interface, for memoise and Shiny
```

## 8.3 Semantics worth stating

**Expiry is lazy and checked on read.** An entry past its deadline is invisible to
`get()`, `has()`, `keys()` and `info()` before anything has deleted it. `expire()`
deletes it. This means a `get()` never has to write, which is what makes reads
non-blocking (§10).

**`get()` returns `default` on a miss; `s[[key]]` raises `dastash_not_found`.** Two
verbs for two intentions, matching DiskCache's `get` versus `__getitem__`, and matching
R's own split between `x[["k"]]` and a default-bearing accessor.

**`add()`, `pop()`, `incr()` and `decr()` are single write transactions**, and are
therefore atomic across processes with no further machinery. `incr()` on a key stored by
`set()` with a non-numeric value raises `dastash_type_error` rather than guessing:
counters are `bit64::integer64` stored as eight bytes with a `codec_counter` marker, so
"is this a counter" is a recorded fact rather than an inference.

**`transact()` runs a function inside one write transaction.** Every `set`/`delete`
inside it commits or aborts together, and the blob-first rule still applies — blobs are
published before the transaction opens, and unlinks are deferred to after it commits.
It is also the performance answer: the mdbx README measures 2000 single-write
transactions at 89× the cost of the same writes batched, and batching is the same win as
weakening durability at none of the risk.

**`memoise()` keys on the canonicalised argument list, not on the function's code.**

```r
slow <- function(exchange, date) fetch(exchange, date)
fast <- s$memoise(slow, expire = 86400, tag = "quotes")
fast("XSWX", as.Date("2026-08-29"))
```

The key is `<name> ‖ 0x00 ‖ key_canon(args)`. Joblib hashes the function body; this
deliberately does not, for the reason `dastash-design.md` §7.2 gives — identity that
depends on implementation invalidates a cache every time a comment moves. `version =`
is the explicit lever for "this function now means something different", and it is the
caller's to pull.

## 8.4 Enumerating

`keys()` is a resumable scan over `meta`, and `prefix` makes the `"ns/key"` convention
into a real access path:

```r
s$keys(prefix = "XSWX/")
s$keys(limit = 1000)                    # first page
s$keys(start = last, limit = 1000)      # next page; start is inclusive, drop the first
```

mdbx 0.1.0 has no upper bound on a scan, so a prefix scan is `start = prefix` plus a
client-side stop at the first key that no longer matches, in chunks. §13 says what
changes when the binding grows cursors.

`keys()` never materialises the whole store unasked: an unbounded scan refuses past
`mdbx_scan_max` (a million records), and dastash passes `limit` rather than relying on
that.

## 8.5 DiskCache correspondence

| DiskCache | dastash | Note |
|---|---|---|
| `Cache(directory, size_limit=, eviction_policy=)` | `stash(dir, size_limit=, eviction=)` | |
| `set(key, value, expire=, tag=, read=)` | `set(key, value, expire=, tag=, codec=)` | `read=True` is `codec_file()` |
| `get(key, default=, read=, expire_time=, tag=)` | `get()`, `path()`, `info()` | split by return type |
| `add`, `pop`, `touch`, `delete`, `incr`, `decr` | same names | |
| `__contains__`, `__getitem__`, `__setitem__` | `has()`, `[[`, `[[<-` | |
| `expire()`, `evict(tag)`, `cull()`, `clear()` | same names | |
| `volume()`, `stats()`, `check(fix=)` | `volume()`, `stats()`, `check(repair=)` | |
| `transact()`, `memoize()` | `transact()`, `memoise()` | |
| `FanoutCache(shards=)` | v1.x, §16 | |
| `Deque`, `Index`, `Lock`, `Semaphore` | not planned | recipes, not a cache |

---

# 9. Expiry, eviction and accounting

## 9.1 Both walk an index from its cheap end

Expiry and eviction are the same operation over different indexes, and the index exists
so that each one stops early:

```r
# expire: the front of `expiry` is the earliest deadline
due <- mdbx_keys(txn, db = expiry, limit = cull_limit, as = "raw")
for (entry in due) { if (when(entry) > now) break; forget(key(entry)) }

# evict: the front of `stored` / `accessed` / `hits` is the eviction candidate
victims <- mdbx_keys(txn, db = index_for(eviction), limit = n, as = "raw")
```

`cull()` expires first, then evicts until `volume()` is under `size_limit`, in bounded
chunks of `cull_limit` so no single call holds the write lock for an unbounded time.
`set()` calls `cull()` opportunistically when the store is over its limit, which is what
keeps the limit honest without a background process — and there is no background
process, by design.

## 9.2 Accounting is exact and O(1)

`counters` is updated in the same transaction as every mutation, so `volume()` and
`size()` are one read of one record rather than a scan. In SQLite a single hot row
updated by every writer would be a contention problem; under mdbx there is exactly one
writer at a time already, so a hot record costs nothing that is not already being paid.

`volume()` reports `mdbx_env_info()$file_size + counters$bytes_blob`. The mdbx file only
ever grows on disk — freed pages are reused, not returned — so `volume()` is bytes
occupied, which is the number a size limit should be about.

## 9.3 The read-side journal

**Maintaining an access time correctly makes every read a write**, which serialises
readers against each other and against writers. DiskCache has exactly this problem and
solves it with a `statistics` switch and batched updates. So does this:

| `touch_on_read` | Behaviour |
|---|---|
| `"never"` | Reads never write. LRU degrades to least-recently-*stored* |
| `"batched"` | **Default.** Reads append `(key, now)` to an in-process buffer |
| `"always"` | Every read is a write transaction. Exact LRU, serialised readers |

The buffer flushes when it exceeds `journal_max` (128), when any write transaction is
about to run anyway, on `cull()`, on `flush()`, and on `close()`. A flush is one write
transaction that rewrites the `accessed` and `hits` index entries and folds in the
hit/miss counters.

**Losing the buffer to a crash costs eviction accuracy, not correctness.** That is the
trade, it is the same one DiskCache makes, and it should be in the documentation rather
than discovered.

Statistics ride the same mechanism, and `statistics = FALSE` by default means an
ordinary read touches nothing at all.

## 9.4 Retention

`retain_until` is written into the meta record from v1 and **not enforced** until the
lifecycle work lands. It costs one field now. `dastash-design.md` §6.3 is right that a
cache eviction that deletes an artifact inside a regulatory retention window is a
compliance incident rather than a cache miss, and that retrofitting the field to a store
that already has data is not possible. `cull()` and `evict()` will refuse to cross it
when they learn to read it.

---

# 10. Concurrency

libmdbx's model is **many readers and one writer, across processes, never within one**,
and the design follows it rather than working around it.

**Reads never block and are never blocked.** A read transaction sees the snapshot that
existed when it began. `get()`, `has()`, `keys()` and `info()` are read transactions, and
because expiry is lazy (§8.3) and access times are journalled (§9.3), they stay read
transactions.

**Writers serialise.** A second writer waits on the lock file. dastash begins write
transactions with `flags = "TRY"` and retries with exponential backoff up to `timeout`,
then raises `dastash_busy`. A blocked worker that never returns is worse than an error
that says the store is busy, and `TRY` is the difference.

**One environment per process, opened in the process that uses it.** An mdbx environment
does not survive `fork()`: `parallel::mclapply()` gives the child the R object but not
the mapping, lock or reader slot, and libmdbx invalidates it. A stash therefore records
the PID that opened it and raises `dastash_forked` — with the instruction to open inside
the worker — rather than letting a confusing native error surface.

```r
parallel::mclapply(keys, function(k) {
  s <- dastash::stash(dir)
  on.exit(s$close())
  s$get(k)
})
```

**Read transactions are short.** A long-lived reader holds back the pages its snapshot
needs, growing the file. Every read in dastash is scoped by `mdbx_with_read()`, and
`check()` calls `mdbx_env_reader_check()` to clear slots left by processes that died.

**What is atomic**, without any additional locking: `set`, `delete`, `add`, `pop`,
`incr`, `decr`, `touch`, and anything inside `transact()`. Eight processes calling
`incr()` on one key produce eight increments.

**What is not**: two processes computing the same expensive value on a miss both compute
it. Both `set()` calls are individually atomic and the last wins, so this is duplicated
work, not corruption. Single-flight leases are v1.x (§16) and the mechanism is
constrained by one rule worth writing down now: **a write transaction must never be held
across a producer call.** Holding it blocks every other writer for the duration of an
HTTP request. A lease is a record claimed in a short write transaction, with an expiry
and a holder, renewed by long-running producers — not the write transaction itself.

---

# 11. Durability, capacity and repair

## 11.1 Durability

`durability` maps onto libmdbx's sync flags:

| Value | Flags | Meaning |
|---|---|---|
| `"safe"` | none | **Default.** Every commit is durable; a crash at any moment leaves the store intact |
| `"fast"` | `SAFE_NOSYNC` | Commits are not flushed. A crash can lose recent transactions; it cannot corrupt the database |
| `"unsafe"` | `UTTERLY_NOSYNC` | Can corrupt beyond recovery. For a store you are prepared to rebuild |

Full durability is the default even though this is a cache, because `set()` returning is
a promise that `get()` will find it, and a user who has to reason about which of their
last N writes survived is being asked to reason about the wrong thing. The mdbx README's
own advice applies: **batching writes into fewer transactions is usually the same win at
no risk**, and `transact()` is how you take it. `"fast"` plus a periodic
`mdbx_env_sync()` remains available and is a reasonable choice for a derived cache.

Note that the failure mode under `"fast"` is the *recoverable* one: a lost metadata
commit after a blob was fsynced leaves an orphan, which is exactly the direction §7
already tolerates.

## 11.2 Capacity

`map_size` is the upper bound the mapped file may grow to, fixed at open. Because values
above `inline_max` live outside the database, the map holds metadata only — roughly a
few hundred bytes per entry — so the 1 GiB default covers millions of entries.

Exhausting it is `MDBX_MAP_FULL`, raised as `dastash_store_full` with the current
`geo_current` / `geo_upper` from `mdbx_env_info()` and the instruction to reopen with a
larger `map_size`. It is a documented operational limit, not a crash.

## 11.3 `check()` and repair

Because indexes are derived (§3.3), most damage is repairable:

| Check | `repair = TRUE` |
|---|---|
| Index entry with no meta record | delete the entry |
| Meta record missing an index entry | insert it |
| Meta record whose blob file is absent | delete the record; count it |
| Blob file with no referring record | delete the file |
| `blobs` refcount disagrees with the records | recompute from `meta` |
| `counters` disagrees with a full scan | recompute |
| Stale file in `tmp/` | delete when its PID is not live and it is over an hour old |
| Stale reader slots | `mdbx_env_reader_check()` |
| `hash = TRUE`: blob bytes do not hash to their name | delete the record and the file |

PID liveness is meaningful here precisely because the deployment envelope is a single
host — `dastash-design.md` §5.3 rejects PID checks on the assumption of containers
across machines, and that assumption is the one §0 corrects.

---

# 12. Errors

Conditions are part of the API, raised through `rlang::abort()` with a class. No bare
`stop()`. Callers need to distinguish "produce it again" from "your store is broken".

| Class | Raised when |
|---|---|
| `dastash_key_invalid` | Key fails validation or canonicalisation; over `KEY_MAX` after digest; `NaN` in a key |
| `dastash_not_found` | `s[[key]]` on an absent or expired key |
| `dastash_type_error` | `incr()` on a non-counter; a value a codec cannot encode |
| `dastash_codec_error` | Encode or decode failed, including a missing Suggests package |
| `dastash_blob_corrupt` | Blob missing, or hash mismatch on read |
| `dastash_busy` | Write lock not acquired within `timeout` |
| `dastash_store_full` | `map_size` exhausted |
| `dastash_readonly` | Write attempted against `readonly = TRUE` |
| `dastash_config_conflict` | An explicit store-level setting disagrees with the persisted one |
| `dastash_version_unsupported` | `format_version` newer than this package understands |
| `dastash_forked` | A stash used in a process that did not open it |

Every class has a constructor and a test asserting its class chain, written before any
feature uses it.

---

# 13. What mdbx 0.1.0 does not have

The binding is at 0.1.0 and its stated 0.2 scope is a cursor API, batch entry points,
and `DUPSORT`. v1 of dastash is designed to need none of them, and to get faster when
they arrive.

| Missing | v1 works by | What 0.2 buys |
|---|---|---|
| Cursor API | `mdbx_keys()` / `mdbx_items()` with `start`, `limit`, `reverse` | Prefix scans that stop at the bound in C, not in R |
| An upper bound on a scan | Client-side prefix check, chunked | Removes the over-read at the end of every prefix scan |
| Batch get/put | One call per record inside one transaction | Fewer crossings into C on `cull()` and bulk load |
| `DUPSORT` | Composite index keys `<value><key>` | Marginal; the composite form is arguably clearer anyway |
| `estimate_range()` | Not needed — the cache has no multi-index intersection | Would matter to the typed layer's `find()`, §17 |

`plan.md` §0 assumed `mdbx_estimate_range()` for ordering posting-list intersections and
`mget`/`mput` for batch operations. Neither exists, and neither is needed by anything in
this document. That is worth recording so the assumption is not inherited.

---

# 14. Testing

**Properties**, executable rather than prose:

```text
get(set(k, v)) ~ v                              per codec, per supported type
decode(encode(v)) ~ v                           per codec, per supported type
canon(canon(k)) == canon(k)                     idempotent
canon(k1) == canon(k2)  <=>  k1 ~ k2            over a generated key domain
order(enc_f64(x)) == order(x)                   over generated doubles, both infinities
order(enc_u64(n)) == order(n)
volume() == sum of encoded sizes                after any sequence of set/delete
size()   == length(keys())
set/delete leaves no index entry without a meta record, and none missing
```

**Golden vectors** in `tests/testthat/golden/key-vectors.csv` freeze the key encoding.
Any change to it fails that file. Identity is frozen by test, not by convention.

**Grep guards** over `R/`: `serialize(` outside the codecs, and any `digest(` call
lacking `serialize = FALSE`.

**Cross-process**, with `callr`, spawning real R sessions — the only tests that can
catch the concurrency and atomicity claims:

```text
8 processes set() the same key         -> no partial file under blobs/, all hashes verify
8 processes incr() one key             -> exactly 8
8 processes set() distinct keys        -> counters exact, every key readable
1 writer + 7 readers during a cull()   -> no reader observes a dangling blob
a writer killed mid-set                -> at most an orphan blob; check() reclaims it
a writer killed mid-delete             -> at most an orphan blob; never a dangling record
```

**Crash injection** for §7: an environment variable that makes the store abort between
publishing a blob and committing, and between committing a delete and unlinking, so both
windows are tested rather than argued.

**Portability**: the key length limit is asserted against `mdbx_limits(4096)` as well as
the running machine, so a 16 KiB-page development box cannot produce a store that a
4 KiB-page CI runner rejects.

---

# 15. Open decisions

Each has a recommended default. Overruling one should be cheap now and expensive later,
which is why they are listed.

**D1 — Is the constructor `stash()` or `cache()`?**
**`stash()`.** `cache` is heavily overloaded in R — `cachem`, `memoise`, `R.cache` — and
the package is called dastash. `stash()` returns a `dastash_stash`. The old design's
`store()` is this object.

**D2 — Inline threshold.** **32 KiB**, matching DiskCache, configurable, store-level.
Below it, mdbx's own storage is faster than a file; above it, the file keeps the map
proportional to metadata and makes §6.3 possible.

**D3 — Access-time policy.** **`"batched"`.** Exact LRU is not worth making every read a
write. `"always"` exists for callers who disagree and can measure it.

**D4 — Default eviction policy.** **`least-recently-stored`**, as in DiskCache. It needs
no read-side write at all, so the default configuration never opens the `accessed`
database and an ordinary read touches nothing.

**D5 — Default durability.** **`"safe"`.** See §11.1. `transact()` recovers most of the
performance without the surprise.

**D6 — Does `get()` verify the blob hash?** **No, not by default.** Hashing a 200 MB
Parquet file on every read defeats the point of `path()`. `check(hash = TRUE)` verifies
on demand, and a corrupt-file read raises `dastash_blob_corrupt` from the codec.

**D7 — Are keys ordered by their canonical encoding, or by a digest?**
**By their canonical encoding**, digested only over `KEY_MAX` (§4.1). A digest would make
every key fixed-width and every prefix scan impossible, and prefix scans are what make
`keys(prefix =)` and the `"ns/key"` convention work.

**D8 — Does the typed dataset layer live in this package?**
**Yes, later, as a layer.** §17. Splitting it into a second package before either exists
is a decision made with no information.

---

# 16. Roadmap

**v1** — §2.

**v1.x** — each of these has its storage requirement already met by v1:

```text
fanout sharding            N environments, key hash picks one; the answer to
                           writer serialisation, and DiskCache's own answer
single-flight leases       a lease record with holder and expiry, claimed in a
                           short write transaction, never held across a producer
retention                  enforce retain_until; cull() and evict() refuse to cross it
                           (field written from v1, §9.4)
namespaces / subcaches     s$sub("prices") over a key prefix; prefix scans exist
gc()                       unreferenced blob reclamation; refcounts exist from v1
lifecycle states           stale-if-error, revalidation hooks, programmable validation
batch get/set              maps onto mdbx 0.2's batch entry points
```

**v2** — remote blob backends behind the narrow `put/get/has/rm/list` interface
`dastash-design.md` D5 already specifies; encrypted blobs; the typed layer of §17.

---

# 17. The typed layer, later

`dastash-design.md` describes something this document does not build: datasets with
declared typed key schemas, producers, partial identifiers, a verification relation
`identify(produce(k)) ⊑ k`, and a mismatch policy. It is a good design and it is not a
cache. It sits **above** one:

```text
dataset(name, keys = list(date = key_date(), exchange = key_character()),
        produce = ..., identify = ..., on_mismatch = "error")
        |
        |  key_canon(key)  ->  a stash key
        |  find(exchange = "XSWX")  ->  an index dastash does not yet maintain
        v
      stash                          <- this document
```

Three things v1 does that make that layer arrive without a migration:

- **The key encoding is the same one** (§4), specified and versioned. A typed schema is a
  constraint over what may be canonicalised, not a different encoding.
- **The meta record has room** for provenance — `produced_at`, `producer_id`, `source`,
  `host`, `user`, `r_version` — and `dastash-design.md` §6.2 is right that provenance
  cannot be retrofitted to a store that already has data. v1 does not write those fields;
  the record format is a named list and adding them is not a migration.
- **The codec is recorded per record** (§3.2), which is what lets a dataset change codec
  without orphaning anything.

The one thing the typed layer needs that v1 deliberately does not build is
`find(field = value)`: an index over *key components*, which requires the schema to know
what the components are. That is a second set of index databases keyed
`i ‖ dataset ‖ field ‖ sort_value ‖ key`, using the `sort_scalar` encoding of §5 and the
same "indexes are derived and rebuildable" property of §3.3. It is designed and it is
not in scope here.

Until then, `dastash-design.md` and `plan.md` should be read as **the design of a
future layer**, not as the design of this package. §0 of this document is the pointer
that says so.
