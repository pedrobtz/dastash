# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

`dastash` is an R package at **design stage, pre-implementation**. `R/` is empty and
`DESCRIPTION` is still a `usethis` placeholder. Three documents carry everything, and
they do not describe the same package:

- **`design.md`** — **the current contract.** A persistent, cross-process disk cache on
  `mdbx`, with DiskCache's API surface. Section references in the form `§7`, `D5` point
  here unless the text says otherwise.
- **`dastash-design.md`** — a *typed artifact store* (dataset schemas, producers,
  identifiers, verification). **Deferred**; it describes a layer that will sit above the
  cache. See `design.md` §0 and §17 for exactly which of its decisions survive.
- **`plan.md`** — the staged plan for that deferred store. Deferred with it. Its §0
  assumes `mdbx_estimate_range()` and `mget`/`mput`, which do not exist.

**Read `design.md` §0 before either of the other two**, or their §-references will
mislead. `design.md` §13 lists what `mdbx` 0.1.0 does not provide.

## What the package does

```text
key -> (metadata in mdbx) -> value inline, or a file on disk
```

DiskCache for R. Persistent, shared between processes, size-bounded, with expiry, tag
eviction, statistics and integrity checking. Small values live inside `cache.mdbx`;
values above `inline_max` become content-addressed files, which is what makes a data
frame a Parquet file `arrow` and `duckdb` can read without R materialising it — the
`polars-diskcache` arrangement. `design.md` §1.1 says why this is not `cachem`, §1.2 why
it is not `storr`.

## Deployment envelope

**Multiple processes on a single host, over a local filesystem.** Several R sessions,
scheduled jobs and workers sharing one directory on one machine. libmdbx needs a working
`mmap` and a working lock file and gets both.

`dastash-design.md` §5.1–§5.2 claim the store sits on Azure Files, blobfuse or a shared
AKS volume, and derive a lock-independent architecture from that. **That premise is
wrong**; the correction is `design.md` §0. It also makes PID liveness checks legitimate
(`design.md` §11.3), which `dastash-design.md` §5.3 rejects.

## Storage

```text
<root>/cache.mdbx                  metadata and every index
<root>/cache.mdbx-lck              libmdbx's lock file
<root>/blobs/<aa>/<hash>[.<ext>]   values above inline_max, content-addressed
<root>/tmp/<pid>-<n>               staging, same device, for atomic rename
```

Named databases replace DiskCache's table-plus-six-indexes: `meta`, `values`, `expiry`,
`stored`, `accessed`, `hits`, `tags`, `blobs`, plus store records in the unnamed main
database. `design.md` §3.1 is the table. Indexes are **created on demand from the
configuration** — nothing opens `accessed` unless eviction is LRU.

## Invariants

Load-bearing, and expensive to repair after a store exists.

- **Publish the blob first, commit the transaction second.** A crash between them leaves
  an unreferenced blob (invisible, reclaimable); the reverse commits a record pointing
  at nothing. `design.md` §7.
- **Delete in the transaction, `unlink()` after it commits.** Collect paths during the
  transaction and remove them only once `mdbx_txn_commit()` returns. Unlinking inside
  the transaction is how the `mdbx` `cache.Rmd` vignette deliberately gets it wrong:
  orphans are recoverable, dangling references are not.
- **Stage via `<root>/tmp/`, never `tempdir()`.** A cross-device rename is a copy, and
  not atomic.
- **Never hash `serialize()` output**, and never call `digest()` without
  `serialize = FALSE`. R's serialisation is unstable across versions and ALTREP
  representations. Identity comes from the explicit text encoding in
  `inst/spec/key-encoding-v1.md`, frozen by golden vectors and versioned
  (`KEY_ENCODING_VERSION`). A test greps `R/` for both and fails on a hit.
- **Index encodings are revisable; the key encoding is not.** Every index is a
  projection of `meta` and can be rebuilt, which is what makes `check(repair = TRUE)`
  possible. This is the same split `plan.md` drew between `canon_scalar` and
  `sort_scalar`.
- **Ordered encoding is not plain big-endian.** `enc_f64()` inverts all bits of a
  negative and sets the sign bit of a non-negative; without that, `-1` sorts above every
  positive number. `design.md` §5. The vignette's `be8()` is correct only for positive
  epoch times.
- **Key and tag length limits are constants, not derived from the page size.**
  `keysize_max` is 2022 bytes at 4 KiB pages and 8166 at 16 KiB, so a machine-derived
  limit makes a macOS-written store unreadable on Linux. `KEY_MAX = 512`,
  `TAG_MAX = 256`; longer keys are digested with the canon kept in the meta record.
- **Decode dispatches on the codec recorded in the meta record**, never the stash's
  current codec, so changing a default codec cannot orphan what is stored.
- **`codec_auto()` never selects a lossy codec.** Parquet is opted into, per call or per
  stash, because it does not round-trip an arbitrary data frame.
- **A write transaction is never held across a producer call.** It blocks every other
  writer for the duration. Single-flight is a lease record claimed in a short
  transaction, not the transaction itself.
- **Reads stay read transactions.** Expiry is lazy and access times are journalled
  (`design.md` §9.3), so an ordinary `get()` writes nothing.
- **Errors come from the fixed taxonomy** in `design.md` §12, raised via
  `rlang::abort()` with a class. No bare `stop()`.
- **R6 is used for `stash` only.** Codecs and keys are plain classed lists with value
  semantics.

## Working with mdbx

`mdbx` 0.1.0 (`../mdbx`, submitted to CRAN). One transaction at a time per environment;
many readers and one writer across processes; an environment does not survive `fork()`,
so open it inside the worker. `?mdbx-concurrency` is the contract.

**Not in 0.1.0:** cursors, batch get/put, `DUPSORT`, `estimate_range()`, and any upper
bound on a scan. Prefix scans are `mdbx_keys(start = prefix, limit = n)` plus a
client-side stop at the first non-matching key, in chunks; `start` is inclusive, so drop
the first element when paging. `design.md` §13 is the table.

`mdbx`'s `vignettes/articles/cache.Rmd` is the working sketch this design started from
and is worth re-reading before touching the storage layer.

## Scope discipline

v1 is the cache and nothing else (`design.md` §2). Fanout sharding, single-flight
leases, namespaces, `gc()`, retention enforcement, lifecycle states and batch operations
are **v1.x**; the typed dataset layer of `dastash-design.md` is **v2**. v1 writes the
fields and maintains the refcounts they need — `retain_until` is written and not
enforced — and stops there.

## Dependencies

`Imports` is short on purpose: rlang, R6, digest, bit64, mdbx — no system dependencies.
`digest` rather than `openssl` avoids a libssl requirement. Optional codecs (`qs2`,
`arrow`/`nanoparquet`) and the `cachem` adapter live in `Suggests` and must degrade to a
clear `dastash_codec_error`, verified by a no-Suggests CI job. Adding a dependency is a
decision, not a convenience.

## Commands

```sh
Rscript -e 'devtools::load_all()'                      # load for interactive work
Rscript -e 'devtools::test()'                          # full test suite
Rscript -e 'devtools::test(filter = "canon")'          # one test file (test-canon.R)
Rscript -e 'testthat::test_file("tests/testthat/test-canon.R")'
Rscript -e 'devtools::document()'                      # roxygen -> NAMESPACE, man/
Rscript -e 'devtools::check()'                         # R CMD check
R CMD build . && R CMD check --as-cran dastash_*.tar.gz
```

Cross-process behaviour is tested by spawning real R sessions with `callr`, and the
crash-window tests in `design.md` §14 are the only ones that can catch the ordering
claims above. Run the full suite — not just a filtered file — before concluding a
storage change is sound.
