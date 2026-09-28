# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

## Repository state

`dastash` is an R package at **design stage, pre-implementation**. `R/`
is empty and `DESCRIPTION` is still a `usethis` placeholder. Seven
documents exist and they do not all describe the same thing:

- **`design.md`** — **the current contract** (v2, 2026-09-10). A
  persistent, cross-process disk cache on `mdbx` with a functional
  `stash_*()` API. Section references `§N`, `Dn` point here unless the
  text says otherwise.
- **`design-v1.md`** — the previous contract: the same storage design
  behind an R6 method API. Superseded. `cache-model.md`,
  `prior-art-diskcache.md` and `functional-api.md` cite *its* section
  numbers; `design.md` §0 has the mapping.
- **`review.md`** — what v1 got right and wrong, every change in v2 with
  its reason, and the external facts verified on 2026-09-10 (F-numbered
  findings).
- **`functional-api.md`** — the argument for the functional surface.
  Absorbed into `design.md` §2–§3; where a signature differs,
  `design.md` wins.
- **`cache-model.md`** — the formal model. `design.md` §4 is its
  summary; read it before arguing about expiry, eviction or the publish
  ordering.
- **`prior-art-diskcache.md`** — what `diskcache` and `polars-diskcache`
  do.
- **`dastash-design.md`** and **`plan.md`** — a *typed artifact store*
  (schemas, producers, identifiers) and its plan. **Deferred**; a layer
  that will sit above the cache. `design.md` §20 says which of its
  decisions survive. `plan.md` §0 assumes `mdbx_estimate_range()` and
  `mget`/`mput`, which do not exist.

**Read `design.md` §0 first**, then `review.md` if you need to know why
something is the way it is.

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
libmdbx needs a working `mmap` and lock file and gets both.
`dastash-design.md` §5.1–§5.2 claim the store sits on Azure Files or
blobfuse and derive a lock-independent architecture from that; the
premise is wrong and `design.md` §0 corrects it. PID liveness checks are
legitimate here (`design.md` §11.3).

## Storage

``` text
<root>/cache.mdbx                  metadata and every index
<root>/cache.mdbx-lck              libmdbx's lock file
<root>/blobs/<aa>/<hash>[.<ext>]   values above inline_max, content-addressed, mode 0444
<root>/tmp/<pid>-<n>               staging, same device, for atomic rename
<root>/tree/...                    derived browsable view, only when stash_tree() ran
```

Named databases: `meta`, `values`, `expiry`, `stored`, `accessed`,
`hits`, `tags`, `blobs`, plus `format`/`config`/`counters` in the
unnamed main database. `design.md` §7.2 is the table. Indexes are
**created on demand from the configuration**; never-expiring entries
have **no** `expiry` row.

## Invariants

Load-bearing, and expensive to repair after a store exists.

- **Publish the blob first, commit the transaction second.** A crash
  between them leaves an unreferenced blob (invisible, reclaimable); the
  reverse commits a record pointing at nothing. `design.md` §8.
- **Delete in the transaction,
  [`unlink()`](https://rdrr.io/r/base/unlink.html) after it commits.**
  Collect paths during the transaction and remove them only once
  `mdbx_txn_commit()` returns. Unlinking inside the transaction is how
  the `mdbx` `cache.Rmd` vignette deliberately gets it wrong.
- **Stage via `<root>/tmp/`, never
  [`tempdir()`](https://rdrr.io/r/base/tempfile.html).** A cross-device
  rename is a copy.
- **Never hash [`serialize()`](https://rdrr.io/r/base/serialize.html)
  output**, and never call `digest()` without `serialize = FALSE`.
  Identity comes from the text encoding in
  `inst/spec/key-encoding-v1.md` (`design.md` §5.2), frozen by golden
  vectors and versioned (`KEY_ENCODING_VERSION`). A test greps `R/` for
  both and fails on a hit. `stash_memoise()` does not use
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
  `design.md` §7.4. The vignette’s `be8()` is correct only for positive
  epoch times.
- **Decode dispatches on the codec recorded in the meta record**, never
  the stash’s current codec. No read verb takes a `codec` argument.
- **`codec_auto()` never selects a lossy codec and never selects a
  `Suggests` codec.** Parquet and qs2 are opted into, per call or per
  stash.
- **Laziness is a recorded `shape`.** A lazy arrow or polars frame
  written to the cache comes back as a scan over the blob, from
  `stash_get()` and from memoised functions.
- **A write transaction is never held across a producer call.**
  Single-flight (v1.x) is a lease record claimed in a short transaction,
  not the transaction itself.
- **Reads stay read transactions.** Expiry is lazy and access times are
  journalled (`design.md` §9.3), so an ordinary `stash_get()` writes
  nothing.
- **One live transaction per handle** (`mdbx` refuses a second). Inside
  `stash_transact()` every verb uses the open one.
- **One environment per process and directory.** `stash()` shares one
  environment between handles on the same path; `mdbx` refuses a second
  `mdbx_env_open()` on a path this process already holds.
- **Every named database the configuration implies is created in one
  write transaction at open.** Read-only handles treat a missing index
  database as empty.
- **Errors come from the fixed taxonomy** in `design.md` §13, raised via
  [`rlang::abort()`](https://rlang.r-lib.org/reference/abort.html) with
  a class and `dastash_error` as parent. No bare
  [`stop()`](https://rdrr.io/r/base/stop.html).
- **No object system.** The stash is an environment with S3 class
  `dastash_stash`; codecs and keys are plain classed lists; memoised
  functions are closures with a class. No R6, no S7.
- **Effects return the stash invisibly; questions return answers.**
  Exceptions: `stash_add()` (logical), `stash_pop()` (value),
  `stash_incr()`/`stash_decr()` (double). A miss is decided by
  `missing(default)`.
- **`Imports` is `mdbx`, `rlang`, `digest`.** Adding a dependency is a
  decision (`design.md` §14.1, D13).

## Working with mdbx

`mdbx` 0.1.0 is **first-party**: <https://github.com/pedrobtz/mdbx>,
checked out at `../mdbx` and installed locally
(`R CMD INSTALL ../mdbx`). Submitted to CRAN, not yet accepted; dastash
reaches CRAN after it. Verified behaviour is recorded in `design.md` §15
and `review.md` §4, and is that of **pedrobtz/mdbx#4** — open on
2026-09-13, and the fix for issues \#2 and \#3 — so install that branch
rather than `main`. The short version:

- Many readers and one writer across processes; **one live transaction
  per environment**, and `mdbx_env_open()` refuses a path this process
  already holds, naming it: “mdbx environment ‘’ is already open in this
  process”. Hence the per-process registry in `design.md` §3.1 — which
  is there to *share* the environment, not to improve the error, and
  which keys on the **normalised** path where `mdbx` compares the
  spelling R gave it.
- `mdbx_txn_begin(env, write = TRUE, flags = "TRY")` fails with
  `MDBX_BUSY` instead of blocking; `mdbx_with_write()` takes no flags,
  so the write loop is dastash’s own.
- There are no condition classes. A libmdbx failure is a plain string
  ending in `(mdbx error N)`; the binding’s own refusals — already open,
  read-only transaction, missing database, belongs to another process —
  carry no code and are recognisable only by their text. `R/engine.R` is
  the only place that reads either (`design.md` §13).
- Named databases are created in a write transaction at open;
  `create = TRUE` in a read transaction is refused whether or not the
  database exists, and a missing one is refused by name in either kind
  of transaction. Neither is catchable by class, so a read-only handle
  asks `mdbx_dbi_list()` which databases exist rather than opening each
  inside a `tryCatch`.
- `mdbx_put(overwrite = FALSE)` returns `FALSE` on an existing key;
  `mdbx_get()` takes `default`; `mdbx_env_stat(txn, db =)$entries` is
  exact.
- An environment does not survive `fork()`; open it inside the worker.
- Always open with `ACCEDE`; the effective sync flags come from
  `mdbx_env_get_flags()`.

**Not in 0.1.0:** cursors, an upper bound on a scan, batch get/put,
`DUPSORT`, `estimate_range()`. Prefix scans are
`mdbx_keys(txn, start = prefix, limit = n, db = )` plus a client-side
stop at the first non-matching key, in chunks; `start` is inclusive, so
drop the first element when paging. `design.md` §15 lists what dastash
asks of `mdbx` 0.2 in priority order; when a gap in the binding hurts,
the fix goes in `../mdbx`, not around it.

All `mdbx_*` calls live in one file (`R/engine.R`); nothing else calls
the binding. `../mdbx/vignettes/articles/cache.Rmd` is the sketch this
design started from.

## Scope discipline

v1 is `design.md` §3 in full and nothing else. Single-flight leases,
stale-while-revalidate, retention enforcement, `stash_reconfigure()`,
fanout sharding, namespaces, a lazy DuckDB round trip and `codec_json()`
are **v1.x** (`design.md` §19); remote blob backends and the typed
dataset layer are **v2**. v1 writes `retain_until` and does not enforce
it.

## Dependencies

`Imports`: rlang, digest, mdbx. Optional codecs and engines (`qs2`,
`nanoparquet`, `arrow`, `duckdb`/`DBI`/`dbplyr`), `bit64`, `cachem`,
`memoise` and `utf8` live in `Suggests` and must degrade to a clear
`dastash_codec_error`, verified by a no-Suggests CI job. The R `polars`
package is not on CRAN and is used only when found installed.

## Commands

``` sh
R CMD INSTALL ../mdbx                                  # the engine, from the sibling checkout
Rscript -e 'devtools::load_all()'                      # load for interactive work
Rscript -e 'devtools::test()'                          # full test suite
Rscript -e 'devtools::test(filter = "key")'            # one test file (test-key.R)
Rscript -e 'testthat::test_file("tests/testthat/test-key.R")'
Rscript -e 'devtools::document()'                      # roxygen -> NAMESPACE, man/
Rscript -e 'devtools::check()'                         # R CMD check
R CMD build . && R CMD check --as-cran dastash_*.tar.gz
```

Build order is `design.md` §18: conditions, then the key encoding and
golden vectors, then the engine file and ordered encodings, then codecs,
then the core with crash injection. Cross-process behaviour is tested by
spawning real R sessions with `callr`, and the crash-window tests in
`design.md` §16 are the only ones that can catch the ordering claims
above. Run the full suite — not just a filtered file — before concluding
a storage change is sound.
