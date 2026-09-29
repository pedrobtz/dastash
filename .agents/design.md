# dastash — a disk cache for R

**Status:** design, pre-implementation. The package skeleton, CI and pkgdown site exist;
`R/` holds only the package documentation. Revised 2026-09-28 for `mdbx` 0.1.1 on CRAN.
**Engine:** [`mdbx`](https://github.com/pedrobtz/mdbx) (≥ 0.1.1), first-party R bindings to
libmdbx, on CRAN. §15 records what it provides, verified by running 0.1.1, and what
dastash asks of its next release.
**Model:** Python's [`diskcache`](https://github.com/grantjenks/python-diskcache) for the
cache, [`polars-diskcache`](https://github.com/lmmx/polars-diskcache) for file-backed
frames, and the R ecosystem's own conventions for the API.

```text
key -> (record in mdbx) -> value inline, or a content-addressed file on disk
```

`dastash` is a persistent, cross-process disk cache for R. A key maps to a value that
outlives the session, is shared by every process on the machine, expires on a clock,
carries tags for bulk invalidation, and is culled when the directory grows past a limit.
Small values live inside one transactional key-value file. Large ones become
content-addressed files, which is how a data frame becomes a Parquet file that `arrow`,
`duckdb` and anything else can read without R materialising it — and how a *lazy* frame
stays lazy across the cache.

The API is functional. The stash is the first argument of every verb, the verbs pipe,
tabular answers are data frames, configuration is ordinary R values, and the whole
surface is one `stash_` prefix away from tab completion.

---

# 0. Documents and envelope

| Document | What it is |
|---|---|
| **`design.md`** (this) | The contract: semantics, API, storage, concurrency, engine |
| `cache-model.md` | The formal model — axioms, `forget_P`, why the orderings of §8 are forced. §4 here is its summary |
| `prior-art-diskcache.md` | What `diskcache` and `polars-diskcache` do and why people use them |
| `roadmap.md` | The build order, stage by stage, and the releases the contract ships in, from 0.1.0 on CRAN to 1.0.0 |
| `typed-layer.md` | The deferred typed dataset layer that sits above this cache (§20) |

Earlier drafts — the first contract behind an R6 method API, its review, the argument for
a functional API, and the design and plan of a typed artifact store — were folded into
these four on 2026-09-28 and removed. They are in git history at commit `c7216c9`. Where a
decision here reverses one of them, §17 says so and why.

**Deployment envelope: many processes on one host, over a local filesystem.** libmdbx
needs a working `mmap` and a working lock file, and a local filesystem provides both.
Several R sessions, scheduled jobs and workers share one directory on one machine. Network
filesystems — NFS, SMB, Azure Files, blobfuse — are out of scope, and PID liveness checks
are legitimate (§11.3).

---

# 1. What this is

```r
library(dastash)

s <- stash("~/.cache/prices")

# key -> value, with expiry and tags ------------------------------------------
s |> stash_set("XSWX/2026-08-29", quotes, expire = 3600, tags = "XSWX")
stash_get(s, "XSWX/2026-08-29")
stash_get(s, "missing", default = NULL)
stash_has(s, c("XSWX/2026-08-29", "missing"))       # TRUE FALSE

# a function, cached across sessions and processes ---------------------------
fetch_prices <- stash_memoise(fetch_prices, s, expire = 86400, tags = "prices")
fetch_prices("XSWX", as.Date("2026-08-29"))         # computes, stores
fetch_prices("XSWX", as.Date("2026-08-29"))         # reads back
stash_forget(fetch_prices, "XSWX", as.Date("2026-08-29"))

# frames become Parquet files other tools can read ---------------------------
load_trades <- stash_memoise(load_trades, s, codec = codec_parquet())
load_trades("XSWX")                                 # a data frame, from Parquet
k <- stash_memoise_key(load_trades, "XSWX")
stash_path(s, k)                                    # ".../blobs/9f/9fbc….parquet"
stash_lazy(s, k) |>                                 # an arrow Dataset, nothing read yet
  dplyr::filter(px > 100) |>
  dplyr::collect()

# a lazy frame in, a lazy frame out ------------------------------------------
scan_trades <- stash_memoise(
  function(dir) arrow::open_dataset(dir) |> dplyr::filter(px > 0),
  s, name = "scan_trades"
)
scan_trades("raw/")                                 # an arrow query over the cached file

# browse it ------------------------------------------------------------------
stash_tree(s)
#> ~/.cache/prices/tree/load_trades/v1/x=XSWX/value.parquet -> ../../../../blobs/9f/9fbc….parquet

# the catalogue is a data frame; maintenance pipes ---------------------------
stash_entries(s, tag = "XSWX")
s |> stash_expire() |> stash_cull()
stash_evict(s, tag = "XSWX")
stash_volume(s)
stash_stats(s)
```

## 1.1 The two models

**From `diskcache`**, the proposition: a cache that outlives the process, is safe to share
between processes, bounds its own size, expires and evicts on a policy you choose, keeps
statistics you opt into, checks and repairs itself, and needs no server. Also its
specific engineering: an ordinary read touches nothing; expiry is lazy; culling is
bounded and happens on the writing side; indexes are created on demand; large values are
files; `memoize` keys on arguments, never on code. `prior-art-diskcache.md` §2–§5.

**From `polars-diskcache`**, three things a general-purpose cache gets wrong for data
frames and this one gets right. A frame is stored as **Parquet**, not as a pickle-shaped
blob, so it is smaller, faster, and readable by other tools. A **lazy** frame that goes
into the cache comes back lazy — a scan over the cached file, so filters and projections
push down into it instead of materialising it. And the content-addressed blob directory
gets a **browsable tree** of human-readable paths, so `ls`, a file browser or a DuckDB glob
can navigate it. `prior-art-diskcache.md` §7.

**From R**, the API. Verbs with the object first, so they pipe; one prefix; plain data
frames; `withr`-style `local_*()`; classed conditions; the `memoise` package's shape for
memoisation; and the `cachem` interface for everything that already speaks it.

## 1.2 Why not the existing packages

| Package | What it is | Why it is not this |
|---|---|---|
| `cachem` | The cache interface `memoise` and Shiny use; `cache_disk()` is one RDS per key with an in-memory index | No transactions, no expiry index, no tags, pruning walks the directory, and its own documentation says it is not for multiple processes. **dastash implements its interface** (§3.10) so its users need not know |
| `storr` | Content-addressed key–value store with pluggable drivers | A store, honestly: no expiry, size limit, eviction, tags or statistics. It answers "where do I put this"; a cache answers "how do I keep this under a gigabyte with eight processes doing it at once" |
| `pins` | Versioned boards over local and cloud storage with metadata | Publishing and sharing, not caching: no expiry or eviction, per-pin directories with their own metadata files, no cross-process transactional guarantees |
| `memoise` | In-memory or `cachem`-backed function memoisation | Keys are `rlang::hash()` of the arguments, which is not stable across R or rlang versions; fine for a session, wrong for a cache that outlives one. `stash_memoise()` uses the specified encoding of §5 |
| `targets` | A dependency graph of computations keyed by code and inputs | Identity derived from implementation; a build system, not a cache |
| `thor` | LMDB bindings | A binding, not a cache; libmdbx is LMDB's maintained descendant |

## 1.3 What the engine changes

`diskcache` asks SQLite for one table and six indexes, none of which needs a join or a
planner. It needs **sorted keys, bounded ordered scans, and atomic multi-step writes**.
libmdbx provides exactly those, and the correspondence is direct:

| `diskcache` on SQLite | `dastash` on mdbx |
|---|---|
| `Cache(key) -> value` | named database `values` |
| the metadata columns | named database `meta`, one record per key |
| `INDEX (expire_time)` | named database `expiry`, key `enc_f64(when) ‖ key` |
| `INDEX (access_time)`, `(store_time)`, `(access_count)` | `accessed`, `stored`, `hits`, same shape |
| `INDEX (tag, rowid)` | `tags`, key `tag ‖ 0x00 ‖ key` |
| `ORDER BY x LIMIT n` | `mdbx_keys(txn, db = x, limit = n)` |
| `WHERE x >= ? ORDER BY x LIMIT n` | `mdbx_keys(txn, db = x, start = k, limit = n)` |
| `ORDER BY x DESC LIMIT 1` | `mdbx_keys(txn, db = x, limit = 1, reverse = TRUE)` |
| `BEGIN … COMMIT` | a write transaction (§10) |
| `filename TEXT` | `<root>/blobs/<aa>/<hash>[.<ext>]` |

What gets harder is that **every ordering decision moves into the key encoding**. SQLite
knows `expire_time` is a number; mdbx knows bytes. §7.4 is that problem, and it is the
one place a mistake is silent.

---

# 2. Conventions

Ten rules. Every exported function follows them; the reference in §3 relies on them.

1. **`stash_` prefix, snake_case, verb last.** `stash_get`, `stash_mget`, `stash_entries`.
   One family, greppable, no collisions with base R.
2. **The stash is the first argument, always, never optional.** That is what makes `|>`
   work. There is no ambient default stash: `stash_set(x, "k")` must be readable without
   knowing whether `x` is a stash or a key. `local_stash()` covers the throwaway case by
   *returning* a stash rather than installing one.
3. **One function, one return type.** A return type never depends on an argument's value.
   `diskcache`'s `get(key, read=, expire_time=, tag=)` breaks this; here it is four
   functions: `stash_get()`, `stash_path()`, `stash_lazy()`, `stash_info()`.
4. **Questions return answers; effects return the stash, invisibly.** `stash_has()`
   returns a logical. `stash_set()` returns the stash so it chains. Four effects return
   their outcome because the outcome is the point: `stash_add()` a logical, `stash_pop()`
   the value, `stash_incr()` and `stash_decr()` the new count.
5. **Scalar functions are scalar; plural functions are named.** `stash_get()` takes one key.
   `stash_mget()` — base R's name for "get several into a list" — takes many. Predicates
   and deletions are vectorised because a vector is the only sensible answer:
   `stash_has(s, keys)`, `stash_delete(s, keys)`.
6. **Tabular answers are plain data frames.** No row names, no factors, no tibble
   dependency, the same class whatever is installed. Pipe into `tibble::as_tibble()` or
   `dplyr` if you want them.
7. **Behaviour is a value; a closed choice is a string; time is R's time.** Codecs are
   objects (`codec_parquet()`), because they carry behaviour. Eviction and durability are
   strings matched with `match.arg()`, because they are enumerations. `expire =` takes a
   number of seconds, a `difftime`, or a `POSIXct`, because R already has those.
8. **Pure things are pure.** Keys, canonicalisation and codecs touch nothing.
   `stash_key()` is testable without a directory.
9. **Errors are classed conditions** (§13), and every function that can miss offers a
   `default` so the common case needs no handler.
10. **`...` is checked.** Every function with `...` before its options calls
    `rlang::check_dots_empty()` unless `...` has a documented meaning. A misspelled
    argument is an error, not a silent no-op.

---

# 3. API

Signatures are normative. Arguments after `...` must be named.

## 3.1 Opening and closing

```r
stash(
  dir,
  ...,
  size_limit    = 1024^3,
  eviction      = c("least-recently-stored", "least-recently-used",
                    "least-frequently-used", "none"),
  inline_max    = 32 * 1024,
  codec         = codec_auto(),
  codecs        = list(),
  durability    = c("safe", "fast", "unsafe"),
  map_size      = 1024^3,
  cull_limit    = 10L,
  statistics    = FALSE,
  touch_on_read = c("batched", "always", "never"),
  timeout       = 60,
  readonly      = FALSE,
  create        = TRUE
)                                    # -> <dastash_stash>

stash_close(stash)                   # -> stash, invisibly. Idempotent
stash_is_open(stash)                 # -> logical(1)
stash_dir(stash)                     # -> character(1), the normalised root

local_stash(dir = tempfile("stash-"), ..., .local_envir = parent.frame())
with_stash(dir, code, ...)
```

`stash()` opens a directory or creates it. §12 says which settings are persisted in the
store and which belong to the handle, and what happens when two processes disagree.
`codecs` registers user-defined codecs (§6.2) for this handle. `create = FALSE` refuses to
create and raises `dastash_not_found` on a missing directory.

**One environment per process and directory.** `mdbx` refuses a second `mdbx_env_open()`
on a path this process already holds, under any spelling — relative, `./`, or through a
symlinked directory (§15) — and an environment runs one transaction at a time. `stash()`
therefore keeps a process-local registry keyed by `normalizePath(dir)`: a second `stash()`
on the same directory returns a new handle on the same environment, and the environment
closes when the last handle closes. The registry exists to *share* the environment; `mdbx`
already detects the conflict. The registry entry also owns the environment's current
transaction (§10), so every handle on one directory sees the same one.

Handles record the PID that opened them and raise `dastash_forked` when used from a
forked child (§10).

`local_stash()` is the `withr` idiom: it creates a stash, registers `stash_close()` on the
calling frame, and returns it. `with_stash()` is the expression form.

The handle is an **environment with S3 class `dastash_stash`**. It has identity and
mutable state and nothing else; no R6, no S7 (D2).

```r
print(s)
#> <dastash_stash> ~/.cache/prices
#>   entries 1,204 · volume 412 MB of 1 GB · eviction least-recently-stored
#>   durability safe · open
```

## 3.2 Keys

```r
stash_key(...)                       # named or unnamed values -> <dastash_key>
stash_key_chr(key)                   # -> character(1): the canonical text
stash_key_hash(key)                  # -> character(1): sha256 hex of the canonical text
```

Every function that takes a `key` accepts a **string**, a **`dastash_key`**, or **any
object the canonical encoding covers** (§5), which is converted on the way in. A string
is used as-is. So these are the same entry:

```r
stash_get(s, "XSWX/2026-08-29")
stash_get(s, stash_key("XSWX/2026-08-29"))

k <- stash_key(exchange = "XSWX", date = as.Date("2026-08-29"))
k
#> <dastash_key> {date=d:2026-08-29,exchange=s:XSWX}
identical(k, stash_key(date = as.Date("2026-08-29"), exchange = "XSWX"))
#> TRUE                                            # field order is not identity
```

Keys are values: comparable, printable, storable in a variable, computable without a
store. `stash_keys()` returns them as the character vector of their canonical text.

## 3.3 Reading

```r
stash_get(stash, key, default)                 # -> the value
stash_mget(stash, keys, default)               # -> named list, one element per key
stash_has(stash, keys)                         # -> logical, one per key
stash_info(stash, key)                         # -> one-row data frame, or NULL
stash_path(stash, key)                         # -> character(1): the blob path
stash_lazy(stash, key, ..., engine = c("arrow", "duckdb", "polars"), con = NULL)
```

**A miss is decided by whether `default` was supplied.** `stash_get(s, k)` raises
`dastash_not_found`; `stash_get(s, k, default = NULL)` returns `NULL`. There is no
sentinel to learn and no ambiguity with a stored `NULL`, which is a legal value:

```r
stash_get(s, "nope")
#> Error in `stash_get()`:
#> ! No entry for key "nope".
#> ℹ Supply `default` to return a value instead of erroring.
```

This is the functional translation of `diskcache`'s two verbs — `get()` with a default,
`cache[key]` that raises — chosen by `missing()`, an ordinary R idiom, rather than by a
second name. `s[[k]]` is `stash_get(s, k)`.

**Expired means absent.** An entry past its deadline is invisible to every reader before
anything has deleted it (§9.1). `stash_has()` is `FALSE`, `stash_get()` misses,
`stash_keys()` omits it.

`stash_mget()` reads every key in one read transaction and returns a named list in the
order given; a missing key takes `default`, or the whole call raises if `default` is
missing. `stash_info()` returns one row with the columns of `stash_entries()` (§3.5).

`stash_path()` returns the file behind a file-backed entry and raises `dastash_type_error`
for an inline one. The value never enters R. The path is stable while the entry lives and
the file is read-only; §6.5 states the contract.

`stash_lazy()` returns a **lazy handle over a Parquet-backed entry**: an `arrow::Dataset`
by default, a `dbplyr` table over `read_parquet()` when `engine = "duckdb"` and a DuckDB
`con` is supplied, or a polars `LazyFrame` when `engine = "polars"`. Nothing is read
until the caller collects. It raises `dastash_type_error` for an entry that is not
Parquet-backed and `dastash_codec_error` when the engine package is not installed. §6.4.

## 3.4 Writing

```r
stash_set(stash, key, value, ..., expire = NULL, tags = NULL, codec = NULL)   # -> stash
stash_mset(stash, values, ..., expire = NULL, tags = NULL, codec = NULL)      # -> stash
stash_add(stash, key, value, ..., expire = NULL, tags = NULL, codec = NULL)   # -> logical(1)
stash_touch(stash, key, expire)                                              # -> stash
stash_delete(stash, keys)                                                    # -> stash
stash_pop(stash, key, default)                                               # -> the value
stash_incr(stash, key, ..., by = 1, default = 0)                             # -> double
stash_decr(stash, key, ..., by = 1, default = 0)                             # -> double
```

**`expire`** is `NULL` or `Inf` for never; a number of seconds from now (zero or negative
means already expired, which tests use); a `difftime`; or a `POSIXct` for an absolute
deadline. `lubridate` users write `expire = hours(6)`, which is a `difftime`. `NaN` and
`NA` are `dastash_type_error`.

**`tags`** is a character vector, at most 16 tags of at most `TAG_MAX` bytes each.
`stash_evict(s, tag = )` deletes every entry carrying the tag. One entry, many tags: an
entry derived from two upstream sources belongs to both.

**`codec`** is `NULL` for the stash default, or a codec object (§6.2). Decode never takes
a codec argument: it dispatches on what the record says was used.

`stash_mset()` takes a **named list** — how R spells a set of key–value pairs — and
commits it in one transaction; names are string keys. `stash_add()` writes only if no
live entry exists and returns whether it landed; an expired entry counts as absent, and
the write itself is `mdbx_put(overwrite = FALSE)`, which answers `FALSE` on an existing
key instead of raising. `stash_touch()` moves a deadline without rewriting the value and
is a no-op on a missing key. `stash_delete()` removes every key given in one transaction.
`stash_pop()` reads and deletes atomically. The counters are atomic across processes,
store a signed 64-bit integer, return a double, and raise `dastash_type_error` on a key
that holds anything but a counter or a value beyond ±2⁵³ (D6).

## 3.5 Enumerating and accounting

```r
stash_keys(stash, ..., prefix = NULL, start = NULL, n = Inf)        # -> character
stash_entries(stash, ..., prefix = NULL, tag = NULL, n = Inf)       # -> data frame
stash_count(stash)                                                 # -> integer(1)
stash_volume(stash)                                                # -> double, bytes
stash_stats(stash)                                                 # -> one-row data frame
```

`stash_keys()` is a resumable scan in key order. `prefix` makes the `"ns/key"` convention
a real access path; `start` (inclusive) with `n` pages through a large store, dropping the
first element of each page after the first. Expired keys are filtered out.

`stash_entries()` returns one row per live entry:

| Column | Type | |
|---|---|---|
| `key` | chr | canonical text |
| `bytes` | dbl | encoded size |
| `codec` | chr | `"rds"`, `"parquet@arrow"`, … |
| `inline` | lgl | `FALSE` when file-backed |
| `blob` | chr | content hash; `NA` when inline |
| `tags` | list of chr | `character(0)` when untagged |
| `shape` | chr | `"value"`, `"file"`, `"lazy"` (§6.4) |
| `stored` | POSIXct | |
| `accessed` | POSIXct | as last flushed (§9.3) |
| `hits` | dbl | as last flushed |
| `expires` | POSIXct | `NA` for never |

`prefix` and `tag` push down into indexes; everything else is `dplyr` on the result.
There is no query language and no data-masking: two explicit filters that map to
indexes, a data frame for the rest (D11).

`stash_count()` is `mdbx_env_stat(txn, db = meta)$entries` — exact, O(1), and immune to
counter drift — and includes entries past their deadline that nothing has reclaimed yet;
`length(stash_keys(s))` excludes those and is O(n). `stash_volume()` is bytes occupied:
the mdbx file plus every blob (§9.2). `stash_stats()` is one row: `count`,
`bytes_inline`, `bytes_blob`, `volume`, `size_limit`, `hits`, `misses`, `evictions`,
`expired`, `eviction`, `durability` (effective, §11.1), `format_version`,
`key_encoding_version`.

## 3.6 Maintenance

```r
stash_expire(stash, ..., n = Inf)                        # -> stash
stash_evict(stash, ..., tag = NULL, prefix = NULL)       # -> stash; exactly one of the two
stash_cull(stash)                                        # -> stash
stash_clear(stash)                                       # -> stash
stash_check(stash, ..., repair = FALSE, hash = FALSE)    # -> data frame of findings
stash_flush(stash)                                       # -> stash
stash_tree(stash, ..., dir = NULL, prefix = NULL)        # -> dir, invisibly
```

All chain except `stash_check()`, which answers a question: one row per finding with
`kind`, `key`, `path`, `detail`, `repaired` (§11.3). `cache-model.md` §4.2 proves
`expire`, `evict`, `cull`, `clear` and `delete` are one operation with five predicates;
they keep five names because each has a different cost and no user should have to
instantiate the abstraction. `stash_flush()` writes out the read journal (§9.3).
`stash_tree()` materialises the browsable tree (§6.6).

## 3.7 Transactions

```r
stash_transact(stash, code)
```

`code` is evaluated in the caller's environment with one write transaction held open on
the stash's environment. Every `stash_set()`, `stash_delete()`, `stash_incr()` inside it
commits or aborts together, and reads inside it see its own writes. A nested
`stash_transact()` joins the outer transaction, as does any verb on another handle to the
same directory (§3.1).

```r
stash_transact(s, {
  stash_delete(s, "old")
  stash_set(s, "new", value)
  stash_incr(s, "generation")
})
```

The stash is named inside the block rather than made ambient — DBI's
`dbWithTransaction()` shape. It costs three characters a line and means the block is
ordinary code that can be extracted into a function without changing meaning.

Two rules survive inside a transaction. Blobs are still published *before* the record is
written and unlinks are still deferred until *after* the commit (§8), so a large
`stash_set()` inside a block is safe and an aborted block leaves at most orphans. And the
transaction blocks every other writer for as long as it is open — **never call a producer
inside it** (§10).

It is also the performance lever. Under full durability every commit is a sync, and a
sync dominates a small write: 2000 single-write transactions took 37 s where the same 2000
writes in one took 0.06 s (§15). That is the win people reach for `durability = "fast"`
to get, at none of the risk.

## 3.8 Memoisation

```r
stash_memoise(
  f, stash, ...,
  expire  = NULL,
  tags    = NULL,
  codec   = NULL,
  key     = NULL,          # function(args) -> key, replaces the default keying
  omit    = NULL,          # argument names excluded from the key
  version = 1L,
  name    = NULL           # defaults to the symbol f was passed as
)                          # -> a function of class c("dastash_memoised", "function")

stash_memoise_key(f, ...)  # -> character(1): the key this call would use
stash_forget(f, ...)       # drop that call's entry           -> f, invisibly
stash_forget_all(f)        # drop every entry of f            -> f, invisibly
is_stash_memoised(f)       # -> logical(1)
```

`stash_memoise()` is to `dastash` what `memoise::memoise()` is to `cachem`: it takes a
function and returns one that consults the stash first. The differences are the point.

**The key is specified, not hashed.** It is

```text
<name> "/v" <version> "/" canon(<matched arguments as a named list>)
```

— a string key, so it prefix-scans, evicts by prefix and browses in the tree. Arguments
are matched to the formals with defaults filled in, so `f(1)` and `f(1, verbose = FALSE)`
are one entry when `FALSE` is the default, and `f(1, x = 2)` and `f(x = 2, 1)` are the
same call. `omit` drops named arguments from identity — `diskcache`'s `ignore=`,
`memoise`'s `omit_args`. `key` replaces the default entirely with a function of the
matched-argument list, which is `polars-diskcache`'s `cache_key=`:

```r
fit <- stash_memoise(fit, s, key = function(args) stash_key(!!!args[c("data_id", "model")]))
```

**The key does not depend on the function's body.** Identity derived from implementation
invalidates the cache every time a comment moves. When the meaning changes, `version =`
is the lever, and it is the caller's to pull. `name` defaults to the symbol `f` was passed
as (`stash_memoise(fetch_prices, s)` → `"fetch_prices"`); an anonymous function needs
`name =` and raises `dastash_key_invalid` without it.

**Anything the encoding cannot cover — connections, environments, functions, S4 objects,
external pointers — is a `dastash_key_invalid` at call time**, with the hint to use
`omit` or `key`. Silently keying on such an argument is the failure mode
`polars-diskcache`'s `repr`-based keys have, and the explicit error is the fix.

**Laziness is preserved** (§6.4). A memoised function that returns an `arrow` query or
Dataset, or a polars `LazyFrame`, has its result written to Parquet by the engine and
returns a lazy scan over that file on a hit. An eager frame comes back eager.
`codec = codec_parquet()` opts eager frames into the file path; without it, a data frame
below `inline_max` is stored inline as RDS like any other value.

**Two companions make the cache addressable.** `stash_memoise_key()` returns the key a
call would use — `diskcache`'s `__cache_key__` — and `stash_forget()` drops it. Without
them, invalidating one result means clearing the store.

**Concurrency is at-least-once.** Two processes missing the same key at once both call
`f`; both `stash_set()` calls are atomic and the last commit wins. That is duplicated work,
not corruption, and `cache-model.md` §12 proves single-flight changes only the count of
calls. Leases are v1.x (§19).

## 3.9 Base generics

```r
length(s)                  # stash_count(s)
s[["k"]]                   # stash_get(s, "k")
s[["k"]] <- value          # stash_set(s, "k", value)
print(s); format(s)
as.list(s)                 # every value; warns above 1000 entries and refuses above 1e5
```

Not implemented, on purpose: `names()` implies cheap and total and it is neither, `[`
because a subset of a cache is not a cache, `$` because `s$get` is the method API this
design rejected (D1).

## 3.10 The `cachem` interface

```r
as_cachem(stash, ..., prefix = "cachem/", expire = NULL, codec = NULL)
```

Returns a list with `get(key, missing)`, `set(key, value)`, `exists(key)`,
`remove(key)`, `reset()`, `keys()`, `prune()`, `size()` and `info()`, so
`memoise::memoise(f, cache = as_cachem(s))` and Shiny's `bindCache()` work unchanged.
`cachem` keys match `^[a-z0-9_-]+$`, which the adapter enforces; they are stored under
`prefix`. This is how the package reaches users who never learn its name.

## 3.11 The complete surface

```r
# open
stash()  stash_close()  stash_is_open()  stash_dir()  local_stash()  with_stash()

# keys and codecs (pure)
stash_key()  stash_key_chr()  stash_key_hash()
codec()  codec_auto()  codec_rds()  codec_raw()  codec_file()  codec_qs2()  codec_parquet()

# read
stash_get()  stash_mget()  stash_has()  stash_info()  stash_path()  stash_lazy()

# write
stash_set()  stash_mset()  stash_add()  stash_touch()  stash_delete()  stash_pop()
stash_incr()  stash_decr()

# enumerate
stash_keys()  stash_entries()  stash_count()  stash_volume()  stash_stats()

# maintain
stash_expire()  stash_evict()  stash_cull()  stash_clear()  stash_check()  stash_flush()
stash_tree()

# compose
stash_transact()  stash_memoise()  stash_memoise_key()  stash_forget()  stash_forget_all()
is_stash_memoised()

# interop
as_cachem()

# generics
length()  [[  [[<-  print()  format()  as.list()
```

Forty-nine names, one prefix, no flag that changes a return type.

## 3.12 Correspondence

| `diskcache` / `plcache` | `dastash` |
|---|---|
| `Cache(directory, size_limit=, eviction_policy=)` | `stash(dir, size_limit=, eviction=)` |
| `set(key, value, expire=, tag=, read=)` | `stash_set(s, key, value, expire=, tags=, codec=)`; `read=True` is `codec_file()` |
| `get(key, default=)` / `cache[key]` | `stash_get(s, key, default)` / `stash_get(s, key)` |
| `get(..., read=True)` / `get(..., expire_time=True, tag=True)` | `stash_path()` / `stash_info()` |
| `add`, `pop`, `touch`, `delete`, `incr`, `decr` | `stash_add`, `stash_pop`, `stash_touch`, `stash_delete`, `stash_incr`, `stash_decr` |
| `key in cache`, `len(cache)`, `iterkeys()` | `stash_has()`, `length()` / `stash_count()`, `stash_keys()` |
| `expire()`, `evict(tag)`, `cull()`, `clear()` | same names, `stash_` prefix |
| `volume()`, `stats()`, `check(fix=)` | `stash_volume()`, `stash_stats()`, `stash_check(repair=)` |
| `transact()`, `memoize(expire=, tag=, ignore=)` | `stash_transact()`, `stash_memoise(expire=, tags=, omit=)` |
| `f.__cache_key__(...)` | `stash_memoise_key(f, ...)` |
| `memoize_stampede`, `FanoutCache`, `Lock`, `Deque` | not in v1 (§19); the last two are not caching features |
| `@cache()` on a frame-returning function | `stash_memoise(f, s, codec = codec_parquet())` |
| a `LazyFrame` comes back a `LazyFrame` | an arrow query or polars `LazyFrame` comes back as a scan of the cached file |
| `cache_key=` callback | `key =` |
| `functions/` symlink tree, `nested=`, `trim_arg=` | `stash_tree()`, always nested, 64-character components |
| blob named by hash of the *call* | blob named by hash of the *content*; identical bytes stored once |
| no expiry | `expire =` |

---

# 4. Semantics

`cache-model.md` is the model; this is the part of it a reader of the API needs.

A cache state is a set of retained writes. A read returns **the most recent retained write
for the key that is still live**, or nothing. Two axioms:

- **Soundness.** A read never returns a value that was not written under that key. This
  is the axiom no implementation may violate; violating it is corruption, not
  forgetfulness. Every genuine bug in a cache is of this form: a record pointing at a
  file that no longer exists, a decode of the wrong blob, a torn write.
- **Forgetfulness.** Retained writes may be dropped at any time, for any reason, with no
  notice.

So the read-after-write law is membership, not equality:

```text
stash_get(s, k)  after  stash_set(s, k, v)   ∈   { v, absent }
```

A store promises the first; a cache promises only that it is one of the two. Callers who
need the value to be there hold it in a variable.

Six consequences shape the design and are theorems rather than choices:

- **Expiry is part of the read, not an operation.** Whether a write is live is a function
  of its deadline and the clock, so a read can decide it without writing anything, and
  `stash_expire()` can only ever reclaim space, never change an answer. Lazy expiry is
  forced, not chosen (§9.1).
- **Every maintenance verb is one operation** — drop the writes satisfying a predicate —
  and each index exists to answer one predicate in order and stop early (§9.1).
- **Eviction policy is semantically free.** Two stashes differing only in policy cannot be
  told apart by any sequence of reads; they differ as consumers of disk. That is why
  access times may be batched, sampled or lost without a correctness cost (§9.3).
- **Least-recently-stored is the only policy that keeps reads pure.** LRU and LFU depend
  on fields only a read can update. That is why it is the default (D4).
- **Content-addressed files must be a superset of what the records reference at every
  instant.** The two update orders in §8 are the only ones that keep that inclusion.
- **A crash under relaxed durability is indistinguishable from an unlucky eviction**, so a
  cache may run with `durability = "fast"`; a mode that can corrupt the file is a
  different kind of thing and is named `"unsafe"` (§11.1).

"Same value" is decided per codec: a codec is lossless on the types it declares, and
`codec_auto()` only chooses lossless ones (§6.2).

---

# 5. Keys

A key is text: a UTF-8 string of at most `KEY_MAX` bytes, stored as its bytes so that
mdbx's byte order is a usable key order and prefix scans work.

## 5.1 Three ways in

- **A character string is its UTF-8 bytes**, after `enc2utf8()`. `"XSWX/2026-08-29"` is
  stored under exactly those bytes. **No Unicode normalisation is applied** (D12):
  base R has no NFC normaliser and this is a cache, where a miss costs a recompute.
  Callers who receive text from filesystems or user input can normalise with
  `utf8::utf8_normalize()` before keying.
- **A `dastash_key`** carries its canonical text.
- **Anything else the grammar covers** is canonicalised (§5.2). An object it does not
  cover raises `dastash_key_invalid`.

There are no raw-vector keys. Every key is printable and `stash_keys()` returns a
character vector (D12).

## 5.2 The canonical encoding

Specified in `inst/spec/key-encoding-v1.md`, versioned by `KEY_ENCODING_VERSION`, and
frozen by golden vectors in `tests/testthat/golden/key-vectors.csv` the day the first
store is written.

```text
key      := text                                  a character(1) not starting with an opener
          | value                                 anything else
value    := "~"                                   NULL
          | tag ":" payload                       length-1 atomic without names
          | tag "[" payload ("," payload)* "]"    atomic vector, length != 1, no names
          | tag "{" name "=" payload ("," …)* "}" named atomic vector
          | "{" name "=" value ("," name "=" value)* "}"   named list, C-sorted by name
          | "(" value ("," value)* ")"            unnamed list, in order
          | "D{" name "=" value ("," …)* "}"      data frame: columns as a named list
tag      := s | i | f | l | r | d | t | u | e     character, integer-valued, double,
                                                  logical, raw, Date, POSIXct, difftime,
                                                  factor
payload  := "!"                                   NA of the tagged type
          | escaped                               percent-escaped UTF-8
opener   := "~" | "#" | "{" | "(" | "D{" | tag ":" | tag "[" | tag "{"
```

Escaping: `%`, every structural byte `, = [ ] { } ( ) : ! ~`, and every byte below
`0x20` or equal to `0x7F` are written `%XX`. Nothing else is. Typical payloads —
`2026-08-29`, `XSWX`, `1000` — are legible.

Per-type rules:

| R value | Encodes as | Rule |
|---|---|---|
| character(1) at top level | the text | unless it starts with an opener, then `s:` + escaped |
| character elsewhere | `s:` | `enc2utf8()`, no normalisation |
| integer, or a double that is whole and within ±2⁵³, or `integer64` | `i:` decimal | `1L`, `1`, `-0` and `bit64::as.integer64(1)` all encode `i:1` |
| any other double | `f:` C99 hex float (`sprintf("%a")`) | exact, portable, locale-free: `0.1` is `f:0x1.999999999999ap-4`; `Inf` is `f:Inf`; `NaN` is `f:NaN`, distinct from `f:!` |
| logical | `l:T`, `l:F`, `l:!` | |
| raw | `r:` lower-case hex | |
| Date | `d:` ISO-8601 | the underlying double is never encoded |
| POSIXct | `t:` ISO-8601 in UTC with microseconds, `Z` | `tzone` is not identity |
| difftime | `u:` seconds, as `i:`/`f:` payload | units are not identity |
| factor | `e:` the label | levels not present are not identity |
| `NULL` | `~` | |
| named list | `{…}` | names sorted in the C locale; a duplicate name is invalid |
| unnamed list | `(…)` | |
| data.frame | `D{…}` | row names ignored |
| a partially named vector or list | invalid | names are all or none |
| function, environment, connection, S4, external pointer, anything else | `dastash_key_invalid` | the hint names `omit =` and `key =` |

Attributes other than `names`, `class` (for the classes above), `levels`, `tzone` and
`units` are ignored. `1L` and `1` agreeing, `Date` never exposing its double, and
timestamps ignoring `tzone` are the three rules that stop the same call producing two
keys; the hex-float rule is what lets `0.1` be a key at all without a declared precision,
which a cache — unlike the typed layer of §20 — must allow (D12).

**Never hash `serialize()` output.** R's serialisation changes across versions and ALTREP
representations; a cache that outlives an R upgrade would silently lose every key. Every
hash is SHA-256 over bytes dastash chose, computed by `tools::sha256sum()` in one internal
file, `R/hash.R` (D13), and the grep guards of §16 enforce both.
This is also why `stash_memoise()` does not use `rlang::hash()`.

## 5.3 Length, and why the limit is a constant

libmdbx bounds key size by page size: `mdbx_limits()$keysize_max` is **2022 bytes on
4 KiB pages and 8166 on 16 KiB pages** (§15). A limit derived from the running machine
would produce a store written on one machine that another cannot open. So:

```text
KEY_MAX = 512 bytes     TAG_MAX = 256 bytes     CANON_KEEP_MAX = 4096 bytes

expiry / stored / accessed / hits entry :   8 + 512        = 520  <= 2022
tags entry                              : 256 + 1 + 512    = 769  <= 2022
```

A key whose text exceeds `KEY_MAX` is stored as `"#" ‖ sha256hex(text)` — 65 bytes.
Its text is kept in the meta record when it is at most `CANON_KEEP_MAX`, so
`stash_keys()` and `stash_entries()` still report the real key; beyond that the record
keeps a 256-byte preview and the length, and `stash_keys()` reports the digest form.
`#` is an opener (§5.2), so a string key that starts with `#` is stored as `s:#…` and can
never be mistaken for a digest. Digesting is a storage detail: equality is still decided
by the canonical text. A
memoised function called with a large vector gets a working, if unprintable, key, and
`key =` is how to give it a better one.

---

# 6. Values, codecs and blobs

## 6.1 Inline or file

A value whose encoded size is under `inline_max` (32 KiB, matching `diskcache`; D5) is
stored in the `values` database. Anything larger is written to a file and the record
keeps a pointer. `codec_file()` and `codec_parquet()` are always file-backed regardless
of size, because the file is their point.

Files are **content-addressed**: `blobs/<aa>/<hash>[.<ext>]` where `hash` is the SHA-256
of the encoded bytes and `<aa>` its first two hex characters. Identical bytes are stored
once, and the `blobs` database holds a refcount so deletion is safe. Content addressing
is about bytes, not values: the same frame written by two codec versions is two blobs,
and that is correct, since the hash exists to answer "is this the file the record means".
The tree (§6.6) is what gives the hash-named directory a human face.

## 6.2 Codecs

```r
codec_auto()                 # the default: raw for raw and bare strings, rds otherwise
codec_rds()                  # serialize(); any R object; lossless
codec_raw()                  # raw vectors and a single string, stored as bytes
codec_file()                 # the value is a path; encode moves or copies it; decode returns a path
codec_qs2()                  # Suggests qs2: faster and smaller than rds for large objects
codec_parquet(engine = c("auto", "nanoparquet", "arrow"), ...)   # Suggests; §6.3

codec(name, encode, decode, ..., ext = NULL, version = 1L, supports = NULL)   # user-defined
```

A codec is a plain classed list with `name`, `version`, `ext`, `encode(value, path)`,
`decode(path, meta)`, and `supports(value)`, a predicate for what it round-trips
losslessly. `encode()` writes to a path (the staging file of §8); for values that will be
inline the same path is read back into the record. It may return a small named list of
decode parameters, which the record keeps as `codec_meta` and passes back to `decode()`:
whether `codec_raw()` stored a string or a raw vector, the extension of the file
`codec_file()` copied, the class of an eager Parquet frame (§6.4). Codecs never see the
store, and never run inside a transaction (§10).

**The record stores the codec name and version, and decode dispatches on it** — never
on the stash's current default. Changing a default codec cannot orphan what is stored.
Built-in codecs are always known; a user-defined codec must be passed in `stash(codecs =)`
by every process that reads its entries, and a record naming a codec the handle does not
know raises `dastash_codec_error` with the name.

`codec_auto()` chooses by the value: a raw vector with no attributes → `codec_raw()`; an
unnamed length-1 character with no attributes → `codec_raw()` as UTF-8 text; everything
else → `codec_rds()`. **It never selects a lossy codec and never selects a codec from
`Suggests`**, so what `codec_auto()` writes on one machine every machine can read. Parquet
and `qs2` are opted into, per call or per stash.

Optional codecs raise `dastash_codec_error` with an install hint when their package is
absent; the no-Suggests CI job proves the message rather than a stack trace is what a
user sees.

## 6.3 The Parquet codec

`codec_parquet()` accepts a data frame (any subclass), an `arrow` `Table` or
`RecordBatch`, an `arrow` `Dataset` or `arrow_dplyr_query`, and a polars `DataFrame` or
`LazyFrame`. Engines:

| Engine | Writes | Reads eagerly | Reads lazily |
|---|---|---|---|
| `nanoparquet` | data frames; no system dependency; preferred for eager frames when installed | data frames | no |
| `arrow` | everything above; a query is evaluated in C++ and written without an R data frame in between | data frames | `open_dataset()` |
| `duckdb` | not used for writing in v1 | via `stash_lazy(engine = "duckdb")` | `read_parquet()` through `dbplyr` |
| `polars` | `DataFrame$write_parquet()`, `LazyFrame$sink_parquet()` | | `pl$scan_parquet()` |

`engine = "auto"` picks `nanoparquet` for a data frame and `arrow` or `polars` for their
own objects. The writing engine is recorded in the codec field (`"parquet@arrow"`) for
diagnostics; any engine reads any file. The R `polars` package is not on CRAN; it is used
when installed and is not a declared dependency.

**What Parquet does not round-trip**, and why it is never automatic: row names; most
attributes; nested list columns under `nanoparquet`; factor levels not present in the
data; `POSIXlt`; anything a column cannot hold. `supports()` says no to those and
`stash_set()` raises `dastash_type_error` before writing anything.

## 6.4 Laziness preserved

The record has a `shape` field: `"value"` for anything decoded back into R, `"file"` for
`codec_file()`, and `"lazy"` when the value that was written was a lazy frame. On a
`"lazy"` entry:

- `stash_get()` and a memoised function return a **lazy scan** over the blob with the
  engine that wrote it — `arrow::open_dataset(path)` for an arrow query or Dataset,
  `pl$scan_parquet(path)` for a polars `LazyFrame` — so dplyr verbs or polars expressions
  compose onto the cached file and only `collect()` reads it.
- `stash_lazy()` returns the same, with `engine =` free to choose another reader.

On an eager Parquet entry, `stash_get()` returns a data frame — a tibble or `data.table`
when the original was one and the package is installed, a `data.frame` otherwise — and
`stash_lazy()` is how to get a scan.

A `dbplyr` table over DuckDB is collected on the way in and stored eager in v1, because a
lazy read needs a connection the cache cannot invent; `stash_lazy(engine = "duckdb",
con = )` is the explicit lazy path for those. This is the one asymmetry with
`polars-diskcache`, and it is stated rather than hidden.

## 6.5 `stash_path()`

`stash_path()` hands out the blob path and journals an access; the value never enters R.

```r
arrow::open_dataset(stash_path(s, "trades"))
DBI::dbGetQuery(con, "select * from read_parquet(?)", list(stash_path(s, "trades")))
```

The path is stable while the entry lives, the file is mode `0444`, and identical content
is one file however many keys reference it. The path is **invalidated by `stash_delete()`,
`stash_cull()`, `stash_evict()`, `stash_clear()` and expiry**, from any process. A caller
holding a path across one of those holds a path to a file that may be gone, and the
documentation says so rather than pretending otherwise. A caller who needs the file to
outlive the entry copies it.

## 6.6 The tree

A content-addressed directory is unbrowsable by construction: `blobs/9f/9fbc…parquet` says
nothing. `polars-diskcache` fixes this with a second, disposable view made of symlinks.

```r
stash_tree(s)                       # -> "<root>/tree", invisibly
stash_tree(s, prefix = "load_trades/")
```

```text
<root>/tree/
  load_trades/v1/x=XSWX/value.parquet          -> ../../../../blobs/9f/9fbc….parquet
  XSWX/2026-08-29/value.rds                    -> ../../../blobs/3a/3a10….rds
  reports/{name=s:q3,year=i:2026}/value.parquet -> ...
```

Rules:

- **Derived, on demand.** `stash_tree()` rebuilds the tree under `dir` (default
  `<root>/tree`) from the live records; nothing maintains it on write (D16). It is a view,
  like an index: `stash_check()` ignores it, `stash_clear()` removes it, and a stale tree
  costs dangling symlinks and nothing else.
- **Path from key.** A string key splits on `/`. A trailing canonical named list —
  what `stash_memoise()` produces — expands to one directory per field, `name=value`,
  which is `plcache`'s `arg0=1000/`. Each component is percent-escaped outside
  `[A-Za-z0-9._=,+@-]`, components `.` and `..` and the empty string are escaped whole,
  and a component over 64 characters is truncated with `~` and eight hex characters of
  its hash appended, so two long arguments cannot collide.
- **Leaf** is `value.<ext>`, a **relative** symlink into `blobs/` so the root can move.
- **File-backed entries only.** Inline values have no file to link. A memoised function
  whose results should appear uses `codec = codec_parquet()` or produces values over
  `inline_max`.
- On a platform where the symlink cannot be created — Windows without developer mode —
  `stash_tree()` raises `dastash_unsupported`. It does not fall back to copies or hard
  links, because both would silently change what `stash_volume()` means.

---

# 7. Storage

## 7.1 Layout

```text
<root>/cache.mdbx                    the environment: metadata and every index
<root>/cache.mdbx-lck                libmdbx's lock file
<root>/blobs/<aa>/<hash>[.<ext>]     values above inline_max, content-addressed, mode 0444
<root>/tmp/<pid>-<n>                 staging on the same device, for atomic rename
<root>/tree/…                        the derived view of §6.6, when materialised
```

The environment opens with `subdir = FALSE`, so it is two files. `blobs/` shards on the
first two hex characters of the hash — 256 directories — so no single directory grows
past what `list.files()` handles comfortably during `stash_check()`.

## 7.2 Named databases

`max_dbs = 16`, leaving room. Databases are created **on demand from the configuration**:
a stash with least-recently-stored eviction never opens `accessed`; one that never tags
never opens `tags`. An index is a cost on every write, and one nobody reads should not
exist.

Creation needs a write transaction, so a read-write `stash()` creates every database its
configuration implies in one write transaction at open. A read-only handle can create
nothing: it reads `mdbx_dbi_list()` once at open and treats a database absent from that
list as empty, which is one call instead of a failed open per index (§15).

| Database | Key | Value | Present when |
|---|---|---|---|
| `meta` | stored key | the record (§7.3) | always |
| `values` | stored key | payload bytes | always |
| `expiry` | `enc_f64(expire) ‖ key` | empty | always; **an entry that never expires has no row** |
| `stored` | `enc_f64(stored) ‖ key` | empty | least-recently-stored |
| `accessed` | `enc_f64(accessed) ‖ key` | empty | least-recently-used |
| `hits` | `enc_u64(hits) ‖ key` | empty | least-frequently-used |
| `tags` | `tag ‖ 0x00 ‖ key` | empty | one row per (tag, key), when tags are used |
| `blobs` | `hash` | `{refs, bytes, ext}` | always |

Exactly one eviction index exists, the one the policy walks; `eviction = "none"` has
none. `stash_entries()` reads `stored`, `accessed` and `hits` from the meta record, not
from the indexes.

Index entries carry the key after eight fixed bytes because entries must be unique — two
records can share a millisecond — and because having the key inside the index means
expiry and eviction never need a second lookup to learn what to delete.

Not indexing `expire = Inf` (D7) removes one write per never-expiring `stash_set()`
and halves the size of `expiry` in the common case; the expiry scan stops at the first
future deadline and would never have reached those rows.

Store-level records live in the unnamed main database, which is why nothing else does:

| Key | Value |
|---|---|
| `format` | `{format_version, key_encoding_version, index_encoding_version, created_at, created_by}` |
| `config` | the persisted settings of §12 |
| `counters` | `{count, bytes_inline, bytes_blob, hits, misses, evictions, expired}` |

## 7.3 The meta record

One record per key, read on every hit, so it is small and the payload is not in it: a
scan of `meta` during `stash_check()` should not drag value bytes through the page cache.

```text
stored        double     epoch seconds UTC
expire        double     deadline; Inf for never
accessed      double     last read, as last flushed (§9.3)
hits          double     read count, as last flushed
bytes         double     encoded size
codec         string     "rds", "parquet@nanoparquet", "counter", …  with version
inline        logical
blob          string     content hash; absent when inline
ext           string     blob extension; absent when inline or none
tags          character  possibly empty
shape         string     "value" | "file" | "lazy"
codec_meta    list       what encode() returned for decode(), when anything (§6.2)
key_text      string     the canonical text, only when the key was digested and fits
key_preview   string     first 256 bytes, only when it did not fit
key_bytes     double     length of the canonical text, only when digested
retain_until  double     written from v1, enforced in v1.x (§9.4)
```

The record is a named list serialised with `serialize(version = 3)`. That is permitted
here — identity never depends on it, and R guarantees that newer versions read older
serialisations — and it makes the record extensible by adding a name, which is how the
provenance fields of §20 arrive without a migration. `format_version` guards a future
compact encoding if record size ever matters.

## 7.4 Ordered encodings

mdbx sorts keys as unsigned bytes, shortest first on a tie. An index over a number must
encode it so that **byte order is numeric order**, and this is the whole difference between
an index that works and one that quietly returns the wrong rows.

**Counters** — `enc_u64(n)`: eight big-endian bytes. Nothing subtle.

**Times and any signed quantity** — `enc_f64(x)`:

```text
bits <- IEEE-754 double of x, big-endian
if (sign bit set)   bits <- bitwNot(bits)         negatives: invert every bit
else                bits[1] <- bits[1] | 0x80     non-negatives: set the sign bit
```

Big-endian IEEE-754 alone is **not** order-preserving: `-1` has its high bit set and would
sort above every positive number, and negatives sort in reverse among themselves. The
transform fixes both and inverts cleanly. The `be8()` in `mdbx`'s
[cache article](https://pedrobtz.github.io/mdbx/articles/cache.html) — the sketch this
design started from — is plain big-endian and is correct there only because it encodes
positive epoch times.

`Inf` sorts last, so a never-expiring deadline needs no special case even where it is
indexed. `NaN` has no position and is rejected at the boundary. The property test is one
line and is in the suite from the first commit:
`identical(order(vapply(x, enc_hex, "")), order(x))` over doubles spanning negatives,
zero, subnormals, large magnitudes and both infinities.

## 7.5 Indexes are derived; metadata is not

Every index database is a projection of `meta` and can be dropped and rebuilt from it.
That is what makes `stash_check(repair = TRUE)` possible, and why the index encodings of
§7.4 may be revised — `index_encoding_version` in the `format` record — while the key
encoding of §5.2 may not. Identity is frozen; ordering is rebuildable.

---

# 8. The two orderings that must not be got wrong

The store is transactional. The filesystem is not. Every correctness argument in this
design is about the seam between them, and there are exactly two rules. Both follow from
one inclusion: **the set of blob files must contain every hash any record references, at
every instant** (`cache-model.md` §11.3).

**Writing: blob first, commit second.**

```text
encode  -> <root>/tmp/<pid>-<n>          same device as blobs/
        -> hash while writing
        -> fsync
        -> rename into blobs/<aa>/<hash>[.<ext>], mode 0444
           (target exists: it is the same bytes; discard the staging file)
                        then one write transaction:
                          put meta record
                          put value (inline) or nothing (blob)
                          put expiry / eviction / tags rows
                          increment blobs[hash].refs
                          update counters
```

A crash between the two leaves an **unreferenced blob**: invisible, harmless, reclaimed
by `stash_check(repair = TRUE)`. The reverse order would commit a record pointing at a
file that does not exist, which is a soundness violation. Staging is in `<root>/tmp`, not
`tempdir()`: a cross-device rename is a copy, and a copy is not atomic.

**Deleting: commit first, unlink second.**

```text
one write transaction:
  read meta                -> expire, stored, accessed, tags, blob
  delete meta, value, every index row
  decrement blobs[hash].refs; if it reached zero, delete the blobs row
                              and collect the path
  update counters
                        then, after mdbx_txn_commit() returns:
                          unlink the collected paths
```

The cache article gets this deliberately wrong and says why: unlinking inside the
transaction means a later failure rolls the metadata back to an entry whose file has
already gone. Orphans are recoverable; dangling references are not. If the process dies
between commit and unlink, the orphan is collected later.

This is why the refcount lives in the same transaction as the record. "Is anyone still
using this file" is a function of the records, and a refcount kept anywhere else can
disagree with them.

On Windows, `file.rename()` fails when the target exists; the target is the same content
and the staging file is discarded. Read-only files must have the attribute cleared before
`unlink()`; the delete path does so.

---

# 9. Expiry, eviction and accounting

## 9.1 Both walk an index from its cheap end

Expiry and eviction are one operation over different indexes, and each index exists so
that its walk stops early:

```r
# expire: the front of `expiry` is the earliest deadline
due <- mdbx_keys(txn, db = expiry, limit = cull_limit, as = "raw")
for (row in due) { if (when(row) > now) break; forget(key_of(row)) }

# evict: the front of `stored` / `accessed` / `hits` is the next victim
victims <- mdbx_keys(txn, db = index_for(eviction), limit = n, as = "raw")
```

`stash_cull()` expires everything due, then evicts until `stash_volume()` is under
`size_limit`, in transactions of at most `cull_limit` victims so no single transaction
holds the write lock for long. `stash_set()` runs one bounded cull when the store is over
its limit, which is what keeps the limit honest without a background process — and there
is no background process, by design. A single value larger than `size_limit` is stored
and everything else is evicted around it, as in `diskcache`; `size_limit = Inf` disables
culling.

`stash_evict(tag =)` walks `tags` from `tag ‖ 0x00`; `stash_evict(prefix =)` walks
`meta` from the prefix. Both stop at the first non-matching key and delete in bounded
chunks.

## 9.2 Accounting is exact and O(1)

`counters` is updated in the same transaction as every mutation, so `stash_volume()` reads
one record; `stash_count()` reads the exact `entries` figure libmdbx keeps for `meta`. A
single hot row would be a contention problem in SQLite; under mdbx there is exactly one
writer at a time already, so the hot record costs nothing that is not already being paid.

`stash_volume()` is `mdbx_env_info()$file_size + counters$bytes_blob`. The mdbx file only
grows on disk — freed pages are reused, not returned — so this is bytes occupied, which is
the number a size limit should be about.

## 9.3 The read journal

Maintaining an access time exactly makes every read a write, which serialises readers
against each other and against the writer. `diskcache` has the problem and solves it with
a `statistics` switch; so does this:

| `touch_on_read` | Behaviour |
|---|---|
| `"never"` | Reads never write. LRU degrades to least-recently-stored |
| `"batched"` | **Default.** Reads append `(key, now)` to an in-process buffer |
| `"always"` | Every read is a write transaction. Exact LRU, serialised readers |

The buffer flushes when it exceeds 128 entries, before any write transaction the handle
is about to run anyway, on `stash_cull()`, on `stash_flush()` and on `stash_close()`. A
flush is one write transaction that rewrites `accessed` and `hits` rows and folds in the
hit and miss counts.

**Losing the buffer to a crash costs eviction accuracy, not correctness** — §4, third
consequence. `stash_entries()$accessed` is documented as "as last flushed", and
`stash_flush()` is exported so a user who asks why it disagrees with what they just did
has an answer. Statistics ride the same mechanism; `statistics = FALSE` by default means an
ordinary read touches nothing at all.

## 9.4 Retention

`retain_until` is written into the record from v1 and **not enforced** until v1.x. It
costs one field now. An eviction that deletes an artifact inside a regulatory retention
window is an incident rather than a miss, and the field cannot be retrofitted to a store
that already has data (`typed-layer.md` §6).

---

# 10. Concurrency

libmdbx's model is **many readers and one writer across processes, one live transaction
per environment**, and the design follows it.

**Reads never block and are never blocked.** A read transaction sees the snapshot that
existed when it began. `stash_get()`, `stash_mget()`, `stash_has()`, `stash_keys()`,
`stash_entries()` and `stash_path()` are read transactions, and because expiry is lazy
and access times are journalled they stay read transactions.

**Writers serialise.** A second writer waits on the lock file. dastash begins every write
transaction itself with `mdbx_txn_begin(env, write = TRUE, flags = "TRY")` —
`mdbx_with_write()` takes no flags — which fails at once with `mdbx_busy` instead of
blocking, and retries with exponential backoff up to `timeout` seconds before raising
`dastash_busy`. A worker that never returns is worse than an error that says the store is
busy. Both behaviours are verified across processes (§15).

**One live transaction per environment.** `mdbx` refuses a second `mdbx_txn_begin()` on
an environment rather than deadlocking. The registry entry of §3.1 therefore owns the
current transaction: inside `stash_transact()` every verb, on every handle to that
directory, uses it; outside one, every verb opens and closes its own. No user code runs
while a transaction is open except the body of `stash_transact()`: codecs encode before
the write transaction and decode after the read transaction has returned the bytes, and
nothing in the API takes a callback that runs inside one.

**One environment per process, opened in the process that uses it.** An environment does
not survive `fork()`: `parallel::mclapply()` gives the child the R object but not the
mapping, lock or reader slot. The handle records its PID and raises `dastash_forked`, with
the instruction to open inside the worker, before `mdbx` can refuse.

```r
parallel::mclapply(keys, function(k) {
  s <- stash(dir)
  on.exit(stash_close(s))
  stash_get(s, k)
})

# callr, mirai, future: the worker is a fresh process; open there
```

**Read transactions are short.** A long-lived reader holds back the pages its snapshot
needs and the file grows. Every read is scoped by `mdbx_with_read()`, and
`stash_check()` calls `mdbx_env_reader_check()` to clear slots left by processes that
died.

**What is atomic** without further machinery: `stash_set`, `stash_mset`, `stash_delete`,
`stash_add`, `stash_pop`, `stash_incr`, `stash_decr`, `stash_touch`, and any block in
`stash_transact()`. Eight processes calling `stash_incr()` on one key produce eight
increments.

**What is not:** two processes missing the same key both compute it (§3.8). That is
duplicated work, and the one rule that constrains the v1.x fix is worth writing down now:
**a write transaction is never held across a producer call.** It blocks every other writer
for the duration of an HTTP request. A lease is a record with a holder and an expiry,
claimed in a short write transaction and renewed by long producers — not the write
transaction itself.

---

# 11. Durability, capacity and repair

## 11.1 Durability

| `durability` | libmdbx flags | Meaning |
|---|---|---|
| `"safe"` | none | **Default.** Every commit is durable; a crash at any moment leaves the store intact |
| `"fast"` | `SAFE_NOSYNC` | Commits are not flushed. A crash can lose recent transactions; it cannot corrupt the file |
| `"unsafe"` | `UTTERLY_NOSYNC` | Can corrupt beyond recovery. For a store you are prepared to rebuild |

Full durability is the default even though this is a cache, because `stash_set()`
returning is read by users as a promise, and a user who has to reason about which of the
last N writes survived is reasoning about the wrong thing. `stash_transact()` recovers
most of the performance with no risk (§3.7). `"fast"` plus a periodic `mdbx_env_sync()` is
a reasonable choice for a purely derived cache, and its failure mode is the recoverable
one: a lost metadata commit after a blob was fsynced is an orphan, the direction §8
already tolerates.

Sync flags are a property of the environment *as currently open*, and a process joining an
open environment inherits them: a joiner asking for `SAFE_NOSYNC` without `ACCEDE` gets
`mdbx_incompatible`, and with `ACCEDE` it gets the incumbent's flags (§15). `stash()`
therefore always passes `ACCEDE` and reports the effective mode from
`mdbx_env_get_flags()` in `stash_stats()`, rather than pretending the argument won.

## 11.2 Capacity

`map_size` is the upper bound the mapped file may grow to, fixed at open. Values above
`inline_max` live outside the file, so the map holds metadata — a few hundred bytes per
entry — and the 1 GiB default covers millions of entries. Exhausting it is
`mdbx_map_full`, raised as `dastash_store_full` with `geo_current` and `geo_upper` from
`mdbx_env_info()` and the instruction to reopen with a larger `map_size`. An operational
limit, not a crash.

## 11.3 `stash_check()` and repair

Because indexes are derived, most damage is repairable:

| Finding (`kind`) | `repair = TRUE` |
|---|---|
| `index_orphan` — index row with no meta record | delete the row |
| `index_missing` — meta record missing an index row | insert it |
| `blob_missing` — record whose file is absent | delete the record; count it |
| `blob_orphan` — file with no referring record | delete the file |
| `refcount_drift` — `blobs.refs` disagrees with the records | recompute from `meta` |
| `counter_drift` — `counters` disagrees with a full scan | recompute |
| `tmp_stale` — file in `tmp/` | delete when its PID is not live and it is over an hour old |
| `reader_stale` — reader slot of a dead process | `mdbx_env_reader_check()` |
| `blob_corrupt` — with `hash = TRUE`, bytes do not hash to the name | delete the record and the file |

PID liveness is legitimate because the deployment is one host (§0). `hash = TRUE` reads
every blob and is the only expensive check; `stash_get()` does not verify hashes on the
way in (D20), because hashing a 200 MB file on every read defeats `stash_path()`.

---

# 12. Configuration

Settings split into two kinds, and the split is not cosmetic.

**Store-level**, persisted in the `config` record and shared by every process:
`size_limit`, `eviction`, `inline_max`, `codec`. The process that creates the store fixes
them. A later `stash()` that passes a *different explicit* value raises
`dastash_config_conflict`; one that passes nothing adopts what is there. Two processes
disagreeing about `inline_max` would produce a store where neither can predict where a
value lives; two disagreeing about `eviction` would maintain different indexes.
Changing a store-level setting is `stash_reconfigure()` in v1.x, which rebuilds the
affected indexes; in v1 it is `stash_clear()`.

**Handle-level**, affecting this session only: `map_size`, `cull_limit`, `statistics`,
`touch_on_read`, `timeout`, `readonly`, `codecs`.

**`durability`** is neither; §11.1.

`readonly = TRUE` opens the environment read-only, disables the journal, and raises
`dastash_readonly` on any write verb, including `stash_expire()` and `stash_cull()`,
before a transaction is attempted.

The `format` record carries `format_version`, `key_encoding_version` and
`index_encoding_version`. A store whose `format_version` or `key_encoding_version` is
newer than the package understands raises `dastash_version_unsupported` at open; a newer
`index_encoding_version` triggers a rebuild through `stash_check(repair = TRUE)`.

---

# 13. Errors

Conditions are part of the API. Every one is raised through `rlang::abort()` with its
class and `dastash_error` as parent, carries structured fields (`key`, `dir`, `path`,
`codec` as applicable), and has a constructor and a test asserting its class chain before
any feature uses it. No bare `stop()`. Callers need to distinguish "compute it again"
from "your store is broken".

| Class | Raised when |
|---|---|
| `dastash_key_invalid` | An object the encoding does not cover; a partially named vector; an anonymous memoised function without `name` |
| `dastash_not_found` | `stash_get()`, `stash_pop()`, `s[[key]]` on an absent or expired key without `default`; `stash()` with `create = FALSE` on a missing directory |
| `dastash_type_error` | `stash_incr()` on a non-counter or past ±2⁵³; `stash_path()` or `stash_lazy()` on an entry of the wrong shape; a value a codec's `supports()` rejects; an `expire` that is `NA` or `NaN` |
| `dastash_codec_error` | Encode or decode failed; a codec package from `Suggests` is not installed; a record names a codec the handle does not know |
| `dastash_blob_corrupt` | A read finds the record's blob file missing. `stash_check()` reports the same condition as a finding instead of raising |
| `dastash_busy` | Write lock not acquired within `timeout` |
| `dastash_store_full` | `map_size` exhausted |
| `dastash_readonly` | A write verb on a read-only handle |
| `dastash_config_conflict` | An explicit store-level setting disagrees with the persisted one |
| `dastash_version_unsupported` | The store's format or key encoding is newer than the package |
| `dastash_forked` | A handle used in a process that did not open it |
| `dastash_closed` | A verb on a closed handle |
| `dastash_unsupported` | The platform or this release cannot do it: symlinks for `stash_tree()`; an eviction policy or value size a release before 1.0.0 does not yet support (`roadmap.md` §0) |
| `dastash_engine_error` | Any other `mdbx` failure, with the original condition as `parent` |

**Translating engine errors.** `mdbx` signals every libmdbx failure as a condition of
class `mdbx_error`, with a subclass named after the status and `code` and `name` fields
(§15). `R/engine.R` catches by class: `mdbx_busy` feeds the retry loop of §10 and becomes
`dastash_busy` when `timeout` runs out, `mdbx_map_full` becomes `dastash_store_full`, and
any other `mdbx_error` becomes `dastash_engine_error`. **No code reads a message's text.**

The binding's own refusals — a second open, a second transaction, a write in a read
transaction, a missing named database, a handle inherited across `fork()` — are
unclassed, and dastash is built never to reach them: the registry (§3.1), the shared
transaction (§10), the read-only check (§12), `mdbx_dbi_list()` at open (§7.2) and the
PID check (§10) each stop the call first. One that gets through anyway is a dastash bug,
and surfaces as `dastash_engine_error`.

```r
rlang::try_fetch(
  stash_get(s, k),
  dastash_not_found    = function(cnd) NULL,
  dastash_blob_corrupt = function(cnd) { stash_check(s, repair = TRUE); NULL }
)
```

---

# 14. Dependencies and the engine file

## 14.1 Dependencies

```text
Depends:   R (>= 4.5)
Imports:   mdbx (>= 0.1.1), rlang
Suggests:  qs2, nanoparquet, arrow, duckdb, DBI, dbplyr, dplyr, bit64, cachem, memoise,
           utf8, testthat (>= 3.0), callr, withr, knitr, rmarkdown
```

`Imports` is short on purpose and adding to it is a decision, not a convenience.

- `mdbx` is the engine: first-party, on CRAN, bundling libmdbx through `cpp11` with no
  system dependency. 0.1.1 is the version §15 was verified against.
- `rlang` for classed conditions, `check_dots_empty()`, and `!!!` in `key =` helpers.
- SHA-256 comes from base R: `tools::sha256sum()`, over bytes or streaming over a file,
  from R 4.5 (D13).
- **No R6, no S7, no bit64, no tibble, no cli.** The handle is an environment (D2);
  `integer64` is recognised by class and formatted through its own methods when present;
  data frames are plain; `rlang::abort()` formats bullets on its own.

Every `Suggests` codec and engine degrades to a `dastash_codec_error` naming the package,
verified by the no-Suggests CI job. `polars` is not on CRAN and is used only when it is
found installed.

## 14.2 The engine file

The design does not abstract the engine — every ordering decision in §7 is an mdbx
decision, and `mdbx` is first-party, so a gap in the binding is fixed in the binding
(D14). The code still talks to it through one internal file, `R/engine.R`, with ten
functions:

```text
engine_open(dir, opts) / engine_close(e)
engine_read(e, fn) / engine_write(e, fn, try)         transactions; fn receives a txn
engine_db(txn, name, create)                          a named database handle
engine_get(txn, db, key) / engine_put / engine_del
engine_scan(txn, db, start, n, reverse)               keys in order, start inclusive
engine_info(e)                                        file size, page size, limits
```

Nothing outside that file calls `mdbx_*`. That buys three things. The error translation of
§13 is one `tryCatch` by class in one place. The `TRY`-and-backoff loop, the prefix stop
on scans and the per-process environment registry are written once. And the storage
layer can be unit-tested against a fake engine without a directory, which keeps the
`callr` suite for the claims only a real process can test. It is not a public extension
point.

---

# 15. The engine: what `mdbx` 0.1.1 provides

Verified on 2026-09-28 against `mdbx` 0.1.1 from CRAN, by reading its source and running
it, in one process and across two, on macOS. The design needs nothing outside this list.

| Call | Shape | Used for |
|---|---|---|
| `mdbx_env_open(path, readonly, create, subdir = FALSE, max_dbs = 16L, map_size, max_readers, mode, flags)` | flags are libmdbx names without `MDBX_`: `ACCEDE`, `SAFE_NOSYNC`, `UTTERLY_NOSYNC`, … | `stash()` |
| `mdbx_env_close()`, `mdbx_env_is_open()`, `mdbx_env_sync()` | | close, `"fast"` mode |
| `mdbx_env_info()`, `mdbx_env_stat()`, `mdbx_env_get_flags()`, `mdbx_env_set_flags()`, `mdbx_flags()` | `mdbx_env_info()` has `file_size`, `geo_current`, `geo_upper`, `mapsize`, `pagesize` | volume, capacity, effective durability |
| `mdbx_env_reader_check()` | | `stash_check()` |
| `mdbx_limits(pagesize)` | `keysize_max` | the §5.3 assertion |
| `mdbx_txn_begin(env, write, flags)`, `mdbx_txn_commit()`, `mdbx_txn_abort()`, `mdbx_txn_state()` | `flags = "TRY"` for a write | `stash_transact()`, the retry loop |
| `mdbx_with_read(env, fun)`, `mdbx_with_write(env, fun)` | no flags | reads |
| `mdbx_dbi_open(txn, name, create)`, `mdbx_dbi_drop()`, `mdbx_dbi_list()` | | named databases, index rebuild |
| `mdbx_put(txn, key, value, overwrite, db)`, `mdbx_get(txn, key, default, as, db)`, `mdbx_del(txn, key, db)` | | records |
| `mdbx_keys(txn, limit, as, db, start, reverse)`, `mdbx_items(...)` | no `end` or `prefix` | scans |

**Observed**, each with the part of the design that depends on it:

| Behaviour | Observed in 0.1.1 | Design |
|---|---|---|
| Errors | Every libmdbx failure is a condition `c("mdbx_<name>", "mdbx_error", "error", "condition")` with `code` and `name`: `mdbx_busy` (−30778), `mdbx_map_full` (−30792), `mdbx_incompatible` (−30784), `mdbx_bad_valsize` (−30781). The binding's own refusals are unclassed `simpleError`s | §13 |
| Second open in one process | Refused, unclassed, naming the incumbent, for the same spelling, a relative one, `./`, and a path through a symlinked directory | §3.1 |
| Second transaction on one environment | Refused, unclassed, rather than deadlocking | §3.1, §10 |
| `TRY` against a writer in another process | `mdbx_busy` at once. Without `TRY` the call blocked until the writer committed (3.6 s for a 4 s writer). A reader proceeded throughout and saw the last commit | §10 |
| `ACCEDE` | A joiner asking for `SAFE_NOSYNC` without it gets `mdbx_incompatible`; with it, the incumbent's flags | §11.1 |
| Named databases | `create = TRUE` in a read transaction is refused whether or not the database exists; a missing database is refused by name in either kind of transaction; both unclassed. `mdbx_dbi_list()` names the existing ones | §7.2 |
| Writes in a read-only environment or transaction | Refused, unclassed | §12 |
| `mdbx_put(overwrite = FALSE)`, `mdbx_del()`, `mdbx_get(default =)` | `FALSE` on an existing key; `TRUE`/`FALSE` for whether a record existed; `default` for an absent key | §3.4 |
| `mdbx_keys(start =)` | Positions at the first key at or after `start` and runs past a prefix; `limit = NULL` is guarded at `mdbx_scan_max` (10⁶) | §3.5, §9.1: stop client-side, always pass `limit` |
| Key size | `keysize_max` 2022 at 4 KiB pages, 8166 at 16 KiB. A key one byte over is `mdbx_bad_valsize`. The empty key stores | §5.3 |
| `mdbx_env_stat(txn, db =)$entries` | Exact within the transaction | `stash_count()` |
| Map exhaustion | `mdbx_map_full` | §11.2 |
| After `fork()` | `mdbx_env_is_open()` is `FALSE` in the child and any use is refused, unclassed, naming the fork | §10 |
| Cost of a commit | 2000 single-put write transactions took 37.4 s; the same 2000 puts in one took 0.058 s (default durability, APFS) | §3.7 |

**What dastash asks of the next `mdbx`**, in priority order, with what each removes here:

| Ask | Removes from dastash |
|---|---|
| An upper bound on scans, `mdbx_keys(end =)` or `prefix =`, stopping in C | the client-side prefix stop and the over-read at the end of every prefix scan (§3.5, §9.1) |
| `mdbx_with_write(env, fun, flags = NULL)`, or a `try = TRUE` argument | the hand-rolled begin/commit/abort loop |
| Batch `mdbx_get()`, `mdbx_put()` and `mdbx_del()` over lists of keys in one crossing | one R–C crossing per record in `stash_mget()`, culls and journal flushes |
| A cursor API, later | nothing v1 needs; prefix scans get cheaper |

**Closed asks.** Classed conditions, once the first ask, are in 0.1.1.
[#2](https://github.com/pedrobtz/mdbx/issues/2) (a second open was documented as
independent, and failed with the lock file's `EAGAIN`) and
[#3](https://github.com/pedrobtz/mdbx/issues/3) (named-database refusals surfaced raw
libmdbx text) were fixed before the first CRAN release. Not asked for: `DUPSORT`, because
composite index keys `<value><key>` are clearer, and `estimate_range()`, which only the
typed layer's `find()` might use (§20).

---

# 16. Testing

**Properties**, executable rather than prose:

```text
stash_get(stash_set(k, v)) ~ v                   per codec, per supported type
decode(encode(v)) ~ v                            per codec, per supported type
canon(canon(k)) == canon(k)
canon(k1) == canon(k2)  <=>  k1 ~ k2             over a generated key domain
canon("text") == "text"                          for text not starting with an opener
order(enc_f64(x)) == order(x)                    over generated doubles, both infinities
order(enc_u64(n)) == order(n)
stash_volume() == sum of encoded sizes           after any sequence of set / delete
stash_count()  == length(stash_keys())           after stash_expire()
no index row without a meta record, none missing after any sequence of mutations
a "lazy" entry returns a lazy handle; collect() ~ the collected original
stash_tree(): one leaf per file-backed live entry, every symlink resolves
```

**Golden vectors** in `tests/testthat/golden/key-vectors.csv` freeze the encoding of §5.2.
**Grep guards** over `R/` fail on `serialize(` outside the RDS codec and the meta record
(§7.3), on `sha256sum(` outside `R/hash.R`, on any use of `digest`, on `mdbx_` outside
`R/engine.R`, and on a bare `stop(`. **A portability assertion** checks `KEY_MAX` and `TAG_MAX` against
`mdbx_limits(4096)` as well as the running machine.

**Cross-process**, with `callr` spawning real R sessions — the only tests that can catch
the concurrency and atomicity claims:

```text
8 processes stash_set() the same key        no partial file under blobs/, all hashes verify
8 processes stash_incr() one key            exactly 8
8 processes stash_set() distinct keys       counters exact, every key readable
1 writer + 7 readers through a cull         no reader observes a dangling blob
8 processes call one memoised function      >= 1 computation, 8 identical results
a writer killed between publish and commit  at most an orphan; stash_check() reclaims it
a writer killed between commit and unlink   at most an orphan; never a dangling record
```

**Crash injection** for §8: an environment variable that aborts the process between
publishing a blob and committing, and between committing a delete and unlinking, so both
windows are tested rather than argued. Run the full suite, not a filtered file, before
concluding a storage change is sound.

---

# 17. Decisions

Each is a decision this document makes and why. Overruling one is cheap now and expensive
after data exists. "Reverses" names what an earlier draft had.

**D1 — The API is functions.** `stash_get(s, …)`, not `s$get(…)`. Functions pipe, pass to
`lapply()`, dispatch, and appear in `methods()` and the NAMESPACE; the package reads like
`fs`, `httr2`, `pins` and `DBI`. Names follow what R users already know: `stash_mget()`
after base `mget()`, `stash_memoise()` after `memoise::memoise()`, and `stash_count()` and
`stash_volume()` rather than an ambiguous `stash_size()`. Reverses the first draft's R6
methods and the functional proposal's `stash_get_many()` and `stashed()`.

**D2 — The handle is an environment with an S3 class; no R6, no S7.** With functions as
the interface the object needs identity, mutability and a print method, which an
environment has. R6 would add a dependency for method syntax the API does not expose;
S7 would add one for validation of a single class. Codecs, keys and memoised functions
are plain classed lists and closures with value semantics.

**D3 — A miss is `missing(default)`.** `NULL` is a legal value, so `default = NULL` cannot
signal absence; a sentinel is a thing to learn; `missing()` is an R idiom that gives both
behaviours from one name.

**D4 — Default eviction is least-recently-stored.** The only policy that needs no write
on a read; the default configuration never opens `accessed` and an ordinary read touches
nothing.

**D5 — Inline threshold 32 KiB, store-level.** Below it mdbx's own storage beats a file;
above it the file keeps the map proportional to metadata and makes §6.3 possible.

**D6 — Counters return doubles; `bit64` is not imported.** A counter past 2⁵³ is not a
cache counter; the storage stays 64-bit; the dependency goes.

**D7 — Never-expiring entries have no `expiry` row.** One write per `stash_set()` saved
and the index halved, for rows the scan could never reach.

**D8 — `expire =` accepts seconds, `difftime` and `POSIXct`.** R already has the types;
`expire_in()`/`expire_at()` constructors would be a second way to say them.

**D9 — Tags are a vector.** The index is one row per (tag, key) either way, and an entry
derived from two sources belongs to both.

**D10 — Enumerations are strings, behaviour is objects.** `eviction` and `durability` are
`match.arg()` strings with `diskcache`'s names, because they are closed choices and those
are the names users search for; codecs are objects, because they carry code. No
`evict_lru()` constructors.

**D11 — `stash_entries()` takes two indexed filters, not data-masked predicates.** Tidy
evaluation with index pushdown by pattern-matching the quosure is a query planner in
disguise, whose fallback is a full scan nobody asked for. `prefix` and `tag` are what the
indexes answer; everything else is `dplyr` on a data frame. For the same reason there is
no general `stash_forget(s, predicate)`: an irreversible bulk delete driven by an
expression is a foot-gun, and the named verbs cover every indexed predicate.

**D12 — Doubles are legal keys, encoded exactly; no NFC normalisation; no raw keys.** A
cache keyed on a memoised function's arguments must accept `0.1`; hex floats make it
exact and portable. Normalisation needs a package base R does not have, and a cache miss
is the whole cost of skipping it. Raw keys would make `stash_keys()` unprintable. The
typed layer may impose precision and normalisation; the cache does not. Reverses the
first draft, which rejected doubles, normalised strings and accepted raw keys.

**D13 — SHA-256 from `tools::sha256sum()`; R ≥ 4.5.** Decided 2026-09-29, over `digest`.
Benchmarked on an Intel i5-8500B: 4 µs for a short key against `digest`'s 12 µs, 215 MB/s
in memory against 168 MB/s, a 512 MB file in 2.6 s against 3.3 s, streamed without
reading it into memory — and one dependency fewer. The price is the floor: R 4.1–4.4
cannot install the package. A pure-R SHA-256 was measured too and is about 25,000× slower
than C, so "our own hash" only means C code. `zucrypt` (first-party, not yet on CRAN) is
the candidate for that: 262 MB/s in memory, but no file input yet, and its hex conversion
costs more than its hash. Hashing lives in `R/hash.R` alone, so switching backends is one
file; the output cannot change, since stored keys and blob names are made of it, and the
golden vectors prove any backend agrees.

**D14 — `mdbx` is the engine, first-party, and all of it is in one file.** No driver
contract and no fallback engine: every ordering decision is an mdbx decision, the binding
is ours, and a gap in it is a feature request (§15). `R/engine.R` isolates the binding
for error translation, the write loop and testing, and is not a public extension point.
Reverses the typed-store plan, which wanted `storr`'s driver contract as insurance
against a binding that did not yet exist.

**D15 — Laziness is a recorded shape, not a flag.** A lazy frame in is a lazy scan out,
decided by what was written, so `stash_get()` and a memoised function behave the same
way for the same entry, and `stash_lazy()` exists for an eager Parquet entry.

**D16 — The tree is derived and on demand.** Maintaining it on every write would put a
symlink into the publish path of §8. Rebuilding it is O(entries) and scoped by `prefix`.

**D17 — `stash_memoise()` keys on `name/version/canon(args)`, with defaults filled in.**
A string key so it prefix-scans, evicts and browses. Defaults included so an omitted
argument and its default are one entry; `omit` and `key` for everything else.

**D18 — Full durability by default.** §11.1.

**D19 — The typed layer lives in this package, later, as a layer.** Splitting it into a
second package before either exists is a decision made with no information.

**D20 — `stash_get()` does not verify blob hashes.** Hashing a 200 MB Parquet file on
every read defeats `stash_path()`; `stash_check(hash = TRUE)` verifies on demand, and a
corrupt file surfaces as `dastash_codec_error` from the decoder.

**D21 — The transaction belongs to the environment, not the handle.** Handles on one
directory share one environment (§3.1), and an environment runs one transaction. If each
handle owned its own, a verb on a second handle inside `stash_transact()` would hit
`mdbx`'s unclassed refusal; owning it in the registry entry makes that verb join the open
transaction instead.

---

# 18. Build order

`roadmap.md` is the build order: eleven stages, ordered by what cannot change after data
exists, grouped into releases from 0.1.0 on CRAN to 1.0.0, which is this document's v1.
Two rules from it bind the design. The key encoding (§5) is frozen before anything touches
disk. And every release writes the final on-disk format, adding only meta-record fields and
derived indexes, so a store written by 0.1.0 opens under every later version.

---

# 19. Roadmap

**v1** — §3, in full.

**v1.x** — each has its storage requirement met by v1:

```text
single-flight leases        a lease record with holder and expiry, claimed in a short
                            transaction, never held across a producer (§10)
stale-while-revalidate      probabilistic early recompute in stash_memoise(); the
                            memoize_stampede recipe
stale-if-error              stash_fallback(f, s): serve the last good value when f fails;
                            a second deadline per record, not a subsystem
                            (cache-model.md §8)
retention                   enforce retain_until; cull and evict refuse to cross it
stash_reconfigure()         change a store-level setting by rebuilding indexes (§12)
fanout sharding             N environments, key hash picks one; the answer to writer
                            serialisation, and diskcache's own
namespaces                  stash_sub(s, "prices") over a key prefix; prefix scans exist
lazy DuckDB round trip      when a connection can be supplied at decode time
batch entry points          when mdbx grows them; stash_mget() gets faster, nothing changes
codec_json()                for a cache other languages read
```

**v2** — remote blob backends behind `put/get/has/rm/list`; encrypted blobs; the typed
layer of §20.

---

# 20. The typed layer, later

`typed-layer.md` describes something this document does not build: datasets with
declared, typed key schemas, producers, partial identifiers, a verification relation
`identify(produce(k)) ⊑ k`, and a mismatch policy. It is a good design and it is not a
cache. It sits above one:

```text
dataset("prices", s, keys = list(date = key_date(), exchange = key_character()),
        produce = ..., identify = ..., on_mismatch = "error")
        |
        |  "prices/" ‖ canon(date = , exchange = )   ->  a stash key
        |  ds_find(prices, exchange = "XSWX")         ->  an index v1 does not maintain
        v
      stash                                          <- this document
```

Three things v1 does that let it arrive without a migration: the key encoding is the same
one, and a schema is a constraint on what may be canonicalised, not a different encoding;
the meta record is a named list with room for provenance — `produced_at`, `producer_id`,
`source`, `host`, `user`, `r_version` — which cannot be retrofitted to data that exists;
and the codec is recorded per record, so a dataset can change codec without orphaning
anything.

The one thing it needs that v1 does not build is `find(field = value)`: an index over
key *components*, which requires a schema to know what the components are. It is one more
index database, `fields`, keyed `dataset ‖ 0x00 ‖ field ‖ 0x00 ‖ sort(value) ‖ key`, using
the order-preserving encodings of §7.4 and the same "indexes are derived" property of §7.5.
Designed in `typed-layer.md` §4, and out of scope here.
