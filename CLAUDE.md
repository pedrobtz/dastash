# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

## Repository state

`dastash` is an R package at **design stage, pre-implementation**. The
`usethis` skeleton, testthat 3e, and the R-CMD-check, coverage and
pkgdown workflows (from `pedrobtz/r-actions`) exist; `R/` holds only
`dastash-package.R` and `DESCRIPTION` is still a placeholder. The design
lives in `.agents/`, five documents:

- **`.agents/design.md`** — **the contract**: semantics, API, storage,
  concurrency, and the engine as verified against `mdbx` 0.1.1. Section
  references `§N` and decisions `Dn` point here unless the text says
  otherwise.
- **`.agents/cache-model.md`** — the formal model. `design.md` §4 is its
  summary; read it before arguing about expiry, eviction or the publish
  ordering.
- **`.agents/prior-art-diskcache.md`** — what `diskcache` and
  `polars-diskcache` do.
- **`.agents/roadmap.md`** — the build order: stages S0–S10 to **0.1.0
  on CRAN**, then 0.2.0 (frames), 0.3.0 (access-aware eviction) and
  1.0.0 (`design.md` v1 complete). Work happens in its stage order; each
  stage ends with tests green and `R CMD check` clean.
- **`.agents/typed-layer.md`** — the typed dataset layer (schemas,
  producers, identifiers). **Deferred**; it sits above the cache and is
  built after it.

**Read `design.md` §0 first.** Earlier drafts (an R6-based first
contract, its review, a functional-API proposal, a typed-store design
and plan) were folded into these on 2026-09-28; they are in git history
at `c7216c9`, and `design.md` §17 records which of their decisions were
reversed and why.

## What the package does

``` text
key -> (record in mdbx) -> value inline, or a content-addressed file on disk
```

`diskcache` for R, with `polars-diskcache`’s file-backed frames:
persistent, shared between processes, size-bounded, with expiry, tags,
statistics and integrity checking. Values under `inline_max` live inside
`cache.mdbx`; larger ones become content-addressed files, which is how a
data frame becomes a Parquet file `arrow` and `duckdb` read without R
materialising it, and how a lazy frame stays lazy across the cache
(`design.md` §6.4). The public API is functions with the stash first:
`stash_get(s, key)`, `s |> stash_set(key, value)`,
`stash_memoise(f, s)`. `design.md` §1.2 says why this is not `cachem`,
`storr`, `pins` or `memoise`.

## Deployment envelope

**Multiple processes on a single host, over a local filesystem.**
libmdbx needs a working `mmap` and lock file and gets both. Network
filesystems are out of scope, and PID liveness checks are legitimate
(`design.md` §0, §11.3).

## Storage

``` text
<root>/cache.mdbx                  metadata and every index
<root>/cache.mdbx-lck              libmdbx's lock file
<root>/blobs/<aa>/<hash>[.<ext>]   values above inline_max, content-addressed, mode 0444
<root>/tmp/<pid>-<n>               staging, same device, for atomic rename
<root>/tree/...                    derived browsable view, only when stash_tree() ran
```

Named databases: `meta`, `values`, `expiry`, `blobs`, one eviction index
(`stored`, `accessed` or `hits`, whichever the policy walks), `tags`
when tags are used, plus `format`/`config`/`counters` in the unnamed
main database. `design.md` §7.2 is the table. Indexes are **created on
demand from the configuration**; never-expiring entries have **no**
`expiry` row.

## Invariants

Load-bearing, and expensive to repair after a store exists.

- **Publish the blob first, commit the transaction second.** A crash
  between them leaves an unreferenced blob (invisible, reclaimable); the
  reverse commits a record pointing at nothing. `design.md` §8.
- **Delete in the transaction,
  [`unlink()`](https://rdrr.io/r/base/unlink.html) after it commits.**
  Collect paths during the transaction and remove them only once
  `mdbx_txn_commit()` returns. Unlinking inside the transaction is how
  `mdbx`’s cache article deliberately gets it wrong.
- **Stage via `<root>/tmp/`, never
  [`tempdir()`](https://rdrr.io/r/base/tempfile.html).** A cross-device
  rename is a copy.
- **Never hash [`serialize()`](https://rdrr.io/r/base/serialize.html)
  output.** Identity comes from the text encoding in
  `inst/spec/key-encoding-v1.md` (`design.md` §5.2), frozen by golden
  vectors and versioned (`KEY_ENCODING_VERSION`). Every hash is SHA-256
  from [`tools::sha256sum()`](https://rdrr.io/r/tools/sha256sum.html),
  called only in `R/hash.R` (D13); `digest` is not a dependency. Guards
  fail on `serialize(` outside the RDS codec and the meta record, and on
  `sha256sum(` outside `R/hash.R`. `stash_memoise()` does not use
  [`rlang::hash()`](https://rlang.r-lib.org/reference/hash.html) for the
  same reason.
- **Keys are text.** A string is its UTF-8 bytes, unnormalised; anything
  else is canonicalised by the grammar in `design.md` §5.2 or is
  `dastash_key_invalid`. No raw keys. Doubles are legal and encoded
  exactly (`sprintf("%a")`); a whole double within ±2⁵³ encodes as an
  integer so `1L` and `1` agree. `KEY_MAX = 512`, `TAG_MAX = 256`,
  constants, not page-derived; longer keys are digested with the text
  kept in the record up to `CANON_KEEP_MAX`.
- **Index encodings are revisable; the key encoding is not.** Every
  index is a projection of `meta` and can be rebuilt, which is what
  makes `stash_check(repair = TRUE)` possible.
- **Ordered encoding is not plain big-endian.** `enc_f64()` inverts all
  bits of a negative and sets the sign bit of a non-negative.
  `design.md` §7.4. The cache article’s `be8()` is correct only for
  positive epoch times.
- **Decode dispatches on the codec recorded in the meta record**, never
  the stash’s current codec. No read verb takes a `codec` argument.
- **[`codec_auto()`](https://pedrobtz.github.io/dastash/reference/codec.md)
  never selects a lossy codec and never selects a `Suggests` codec.**
  Parquet and qs2 are opted into, per call or per stash.
- **Laziness is a recorded `shape`.** A lazy arrow or polars frame
  written to the cache comes back as a scan over the blob, from
  `stash_get()` and from memoised functions.
- **A write transaction is never held across a producer call.**
  Single-flight (v1.x) is a lease record claimed in a short transaction,
  not the transaction itself.
- **Reads stay read transactions.** Expiry is lazy and access times are
  journalled (`design.md` §9.3), so an ordinary `stash_get()` writes
  nothing.
- **One environment per process and directory; one transaction per
  environment.** `stash()` shares one environment between handles on the
  same normalised path, and the registry entry — not the handle — owns
  the current transaction, so every handle inside `stash_transact()`
  joins it (`design.md` §3.1, §10, D21). No user code runs inside a
  transaction except the body of `stash_transact()`: codecs encode
  before the write and decode after the read.
- **Every named database the configuration implies is created in one
  write transaction at open.** Read-only handles read `mdbx_dbi_list()`
  once and treat a missing index database as empty.
- **Errors come from the fixed taxonomy** in `design.md` §13, raised via
  [`rlang::abort()`](https://rlang.r-lib.org/reference/abort.html) with
  a class and `dastash_error` as parent. No bare
  [`stop()`](https://rdrr.io/r/base/stop.html). Engine errors are
  translated **by class**, never by message text.
- **No object system.** The stash is an environment with S3 class
  `dastash_stash`; codecs and keys are plain classed lists; memoised
  functions are closures with a class. No R6, no S7.
- **Effects return the stash invisibly; questions return answers.**
  Exceptions: `stash_add()` (logical), `stash_pop()` (value),
  `stash_incr()`/`stash_decr()` (double). A miss is decided by
  `missing(default)`.
- **`Depends: R (>= 4.5)`; `Imports` is `mdbx (>= 0.1.1)` and `rlang`.**
  Adding a dependency is a decision (`design.md` §14.1, D13).

## Working with mdbx

`mdbx` is **first-party** (<https://github.com/pedrobtz/mdbx>) and **on
CRAN**; 0.1.1 is the version the design was verified against, and
`design.md` §15 records what it does. The short version:

- Many readers and one writer across processes; **one live transaction
  per environment**. `mdbx_env_open()` refuses a path this process
  already holds, under any spelling (relative, `./`, symlinked
  directory) — hence the registry in `design.md` §3.1, which is there to
  *share* the environment.
- **Classed conditions.** Every libmdbx failure is
  `c("mdbx_<name>", "mdbx_error", ...)` with `code` and `name` fields:
  `mdbx_busy`, `mdbx_map_full`, `mdbx_incompatible`, `mdbx_bad_valsize`.
  The binding’s own refusals — second open, second transaction, write in
  a read transaction, missing named database, use after `fork()` — are
  unclassed, and dastash is designed never to reach them. `R/engine.R`
  is the only place that catches either (`design.md` §13).
- `mdbx_txn_begin(env, write = TRUE, flags = "TRY")` fails with
  `mdbx_busy` instead of blocking; `mdbx_with_write()` takes no flags,
  so the write loop is dastash’s own.
- Named databases are created in a write transaction; `create = TRUE` in
  a read transaction is refused whether or not the database exists, and
  a missing one is refused by name in either kind of transaction.
- `mdbx_put(overwrite = FALSE)` returns `FALSE` on an existing key;
  `mdbx_get()` takes `default`; `mdbx_del()` returns whether a record
  existed; `mdbx_env_stat(txn, db =)$entries` is exact.
- An environment does not survive `fork()`; open it inside the worker.
- Always open with `ACCEDE`; the effective sync flags come from
  `mdbx_env_get_flags()`.

**Not in 0.1.1:** cursors, an upper bound on a scan, batch get/put/del,
`DUPSORT`, `estimate_range()`. Prefix scans are
`mdbx_keys(txn, start = prefix, limit = n, db = )` plus a client-side
stop at the first non-matching key, in chunks; `start` is inclusive, so
drop the first element when paging, and always pass `limit`
(`limit = NULL` is guarded at `mdbx_scan_max`). `design.md` §15 lists
what dastash asks of the next release in priority order; when a gap in
the binding hurts, the fix goes into `pedrobtz/mdbx`, not around it.

All `mdbx_*` calls live in one file (`R/engine.R`); nothing else calls
the binding, and a grep guard enforces it. `mdbx`’s [cache
article](https://pedrobtz.github.io/mdbx/articles/cache.html) is the
sketch this design started from.

## Scope discipline

v1 is `design.md` §3 in full and nothing else. Single-flight leases,
stale-while-revalidate, stale-if-error, retention enforcement,
`stash_reconfigure()`, fanout sharding, namespaces, a lazy DuckDB round
trip and `codec_json()` are **v1.x** (`design.md` §19); remote blob
backends and the typed dataset layer are **v2**. v1 writes
`retain_until` and does not enforce it.

## Dependencies

`Depends`: R (\>= 4.5). `Imports`: `mdbx (>= 0.1.1)`, rlang. Optional
codecs and engines (`qs2`, `nanoparquet`, `arrow`,
`duckdb`/`DBI`/`dbplyr`), `bit64`, `cachem`, `memoise` and `utf8` live
in `Suggests` and must degrade to a clear `dastash_codec_error`,
verified by the `nosuggests` job of the shared R-CMD-check workflow. The
R `polars` package is not on CRAN and is used only when found installed.

## Commands

``` sh
Rscript -e 'install.packages("mdbx")'                  # the engine, from CRAN
Rscript -e 'devtools::load_all()'                      # load for interactive work
Rscript -e 'devtools::test()'                          # full test suite
Rscript -e 'devtools::test(filter = "key")'            # one test file (test-key.R)
Rscript -e 'testthat::test_file("tests/testthat/test-key.R")'
Rscript -e 'devtools::document()'                      # roxygen -> NAMESPACE, man/
Rscript -e 'devtools::check()'                         # R CMD check
R CMD build . && R CMD check --as-cran dastash_*.tar.gz
```

Build order is `.agents/roadmap.md`: conditions, then the key encoding
and golden vectors, then the engine file and ordered encodings, then
codecs, then the core, blobs with crash injection, and the rest of
0.1.0. A release before 1.0.0 implements a subset of `design.md` §3 but
always writes the final on-disk format. Cross-process behaviour is
tested by spawning real R sessions with `callr`, and the crash-window
tests in `design.md` §16 are the only ones that can catch the ordering
claims above. Run the full suite — not just a filtered file — before
concluding a storage change is sound.
