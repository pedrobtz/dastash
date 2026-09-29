# dastash — roadmap to 0.1.0 on CRAN

**Status:** plan, written 2026-09-29. `design.md` is the contract; this is the order in
which it gets built and the releases it ships in. Stages are ordered by what cannot change
once a store exists, and every stage ends with its tests green and `R CMD check` clean.

---

# 0. Releases

`design.md` calls the full contract "v1". It ships over several releases, each a subset
that writes the **final on-disk format**. Every later feature is either a new field in the
meta record, which is a named list that takes new names without a migration (`design.md`
§7.3), or a new index, which is derived and created on demand at open (§7.2, §7.5). A
store written by 0.1.0 is therefore readable and extendable by every later version.

| Release | Theme | Adds |
|---|---|---|
| **0.1.0** | **A persistent, cross-process cache** — CRAN | Keys, codecs (rds, raw, file), inline and blob storage, expiry, tags, a size limit with least-recently-stored eviction, transactions, `stash_check()`, `stash_memoise()`, `as_cachem()` |
| 0.2.0 | Frames | `codec_parquet()` and its engines, `shape` and laziness, `stash_lazy()`, `stash_tree()`, `codec_qs2()` |
| 0.3.0 | Access-aware eviction | The read journal (`touch_on_read`), `statistics`, `stash_flush()`, least-recently-used and least-frequently-used eviction, hit and miss counts |
| 1.0.0 | `design.md` v1, complete | Performance at 10⁴ and 10⁶ entries, the full `callr` suite at scale, the remaining vignettes |

After 1.0.0, `design.md` §19's v1.x list (leases, stale-while-revalidate, retention, …),
then the typed layer (`typed-layer.md`).

**Why 0.1.0 is this subset.** It is what people use `diskcache` for most: persistent,
shared memoisation with expiry and a size bound (`prior-art-diskcache.md` §2.1). It needs
the full key grammar, because `stash_memoise()` keys on structured arguments. It needs
blobs, because the file layout and publish ordering are the invariants most expensive to
get wrong later. It does not need Parquet, laziness or the read journal, and each of
those adds fields and indexes without touching what 0.1.0 wrote.

**What 0.1.0 does not accept yet**, stated so its API is a strict subset of 1.0.0's:

- `eviction` is `"least-recently-stored"` or `"none"`. The other two arrive with the
  journal in 0.3.0; asking for them raises `dastash_unsupported`.
- `touch_on_read` and `statistics` are not arguments yet. `stash_stats()` has no `hits` or
  `misses` columns until 0.3.0.
- No `stash_lazy()`, `stash_tree()`, `codec_parquet()` or `codec_qs2()`.

---

# 1. Milestones

```text
S0 -> S1 ─┬─> S4 -> S5 -> S6 -> S7 -> S8 -> S9 -> S10 -> CRAN
S0 -> S2 ─┤
S0 -> S3 ─┘
          M1        M2                      M3          M4
```

| Milestone | After | Meaning |
|---|---|---|
| **M1** walking skeleton | S4 | `stash()`, get, set, has, delete, keys on a real directory, from two processes |
| **M2** format frozen | S6 | Key encoding, layout, meta record, blob publishing and deletion: everything a store holds. After M2 a format change is a `format_version` bump, not an edit |
| **M3** feature-complete | S9 | Everything in 0.1.0; only documentation and release work remain |
| **M4** on CRAN | S10 | 0.1.0 accepted |

S1, S2 and S3 are independent after S0 and can proceed in any order.

---

# 2. Stages

Each stage lists what it delivers, what it freezes, how it is tested, and when it is done.

## S0 — Foundation

**Delivers**

- `DESCRIPTION`: real `Title`, `Description` and `Authors@R` (with `cph`);
  `Depends: R (>= 4.5)` (raised from 4.1 in S1, D13); `URL` and `BugReports`. Each
  dependency of `design.md` §14.1 is declared in the stage that first uses it — `rlang`
  here, `mdbx` in S2 — because R CMD check notes an import that nothing uses.
- `tests/testthat.R` runs the tests only when testthat is installed, so the `nosuggests`
  job skips them instead of failing.
- `.Rbuildignore`: add `^\.agents$` and `^CLAUDE\.md$`, both of which would otherwise
  ship in the tarball and draw a NOTE.
- `R/conditions.R`: `dastash_abort()` and one constructor per class in `design.md` §13,
  each with `dastash_error` as parent and its structured fields.
- CI: `nosuggests: true` on the shared R-CMD-check workflow, and no compiler containers,
  since dastash has no compiled code. Pull requests carry the `full-ci` label, so the full
  matrix gates every merge.
- `tests/testthat/test-guards.R`: the grep guards of `design.md` §16 — `serialize(` only
  in the RDS codec and the meta record, `sha256sum(` only in `R/hash.R` and no `digest`
  (added in S1), no `mdbx_` outside `R/engine.R`, no bare `stop(`.
- Remove the `usethis` placeholder test and README text.

**Freezes** the error vocabulary.

**Tests** One per condition class asserting its class chain and fields.

**Done when** `R CMD check --as-cran` is clean on the CI matrix and the `nosuggests` job
passes.

## S1 — Keys

Pure R, no I/O. Stage 1 comes before anything that touches disk because the encoding
cannot be revised once a store exists.

**Delivers**

- `R/hash.R`: SHA-256 over bytes, text and files through `tools::sha256sum()` (D13), and
  `Depends: R (>= 4.5)`, with the oldrel CI runner dropped.
- `R/key.R`: the full grammar of `design.md` §5.2 — text keys with the opener rule,
  `NULL`, atomic scalars and vectors, named and unnamed lists, data frames, the per-type
  rules, percent-escaping, and `dastash_key_invalid` with the `omit =`/`key =` hint for
  everything else.
- `stash_key()`, `stash_key_chr()`, `stash_key_hash()`, `format()` and `print()` methods.
- The storage form (`design.md` §5.3): `KEY_MAX`, `TAG_MAX`, `CANON_KEEP_MAX`, and the
  `"#" ‖ sha256hex(text)` digest for long keys. `#` is an opener, so a literal string key
  starting with `#` is stored as `s:#…` and cannot collide with a digest.
- `inst/spec/key-encoding-v1.md`: the normative grammar, `KEY_ENCODING_VERSION = 1L`.
- `tests/testthat/golden/key-vectors.csv`: value, canonical text, hash. Any change to the
  encoding fails this file.

**Freezes** the key encoding.

**Tests** Golden vectors; property tests for idempotence, injectivity over a generated
domain, `canon("text") == "text"` for text not starting with an opener; `1L`, `1`, `-0`
and `integer64(1)` agree; `0.1` is exact; `tzone`, units and unused levels are not
identity; field order is not identity.

**Done when** the spec is written, the golden file committed, and the property suite
green.

## S2 — Engine and ordered encodings

**Delivers**

- `R/encode.R`: `enc_f64()`, `enc_u64()` and their inverses (`design.md` §7.4).
- `R/engine.R`, the only file that calls `mdbx` (`design.md` §14.2):
  `engine_open()` / `engine_close()` with the per-process registry keyed by
  `normalizePath()`, which owns the environment's current transaction (D21);
  `engine_read()`; `engine_write()` with the `TRY` and backoff loop; `engine_db()`;
  `engine_get()` / `engine_put()` / `engine_del()`; `engine_scan()` with the client-side
  prefix stop and paging; `engine_info()`. Translation by class: `mdbx_busy` →
  `dastash_busy`, `mdbx_map_full` → `dastash_store_full`, any other `mdbx_error` →
  `dastash_engine_error`.
- A PID check on every engine entry point → `dastash_forked`.

**Freezes** the ordered encodings, as `index_encoding_version = 1`. They remain
revisable, since indexes are rebuilt from `meta`, but a revision costs a rebuild.

**Tests** `order(enc_f64(x)) == order(x)` over negatives, zero, subnormals, large
magnitudes and both infinities; round trips; the registry shares one environment across
handles and spellings; nested writes join the open transaction; `mdbx_busy` is retried
then raised as `dastash_busy` (with a second process holding the lock, via `callr`);
`mdbx_map_full` becomes `dastash_store_full`; prefix scans stop and page correctly.

## S3 — Codecs

**Delivers** `R/codec.R`: `codec()`, `codec_rds()`, `codec_raw()`, `codec_file()`,
`codec_auto()`, each with `name`, `version`, `ext`, `encode(value, path)`,
`decode(path)` and `supports()`.

**Freezes** codec names and versions as recorded in the meta record.

**Tests** A codec × type round-trip matrix: atomic vectors, `NA`, attributes, `POSIXct`
with a timezone, `Date`, factors, data frames with row names, nested lists, raw, a bare
string, a file path. `codec_auto()` never picks anything but raw or rds.

## S4 — Walking skeleton — **M1**

The thin slice: a working stash with inline values only, through every layer.

**Delivers**

- `R/store.R`: layout creation (`cache.mdbx`, `blobs/`, `tmp/`), the `format` record,
  the `config` record with store-level settings and `dastash_config_conflict`,
  `dastash_version_unsupported`, creation of every named database the configuration
  implies in one write transaction, `mdbx_dbi_list()` for read-only handles.
- `R/record.R`: the meta record of `design.md` §7.3, serialised with
  `serialize(version = 3)`, with the fields 0.1.0 writes.
- `R/stash.R`: `stash()`, `stash_close()`, `stash_is_open()`, `stash_dir()`,
  `local_stash()`, `with_stash()`, `print()`; `readonly` → `dastash_readonly` before any
  transaction; `dastash_closed`.
- `stash_get()` with `missing(default)`, `stash_mget()`, `stash_set()`, `stash_mset()`,
  `stash_has()`, `stash_delete()`, `stash_keys(prefix =, start =, n =)`,
  `stash_count()`, the `counters` record.
- Values are inline only at this stage; a value over `inline_max` raises
  `dastash_unsupported` until S6.

**Tests** Round trips per codec through a real store; a miss with and without `default`;
a stored `NULL`; a second `stash()` on the same directory shares the environment; config
conflict; read-only handle; a `callr` process reads what this one wrote.

## S5 — Expiry and the atomic verbs

**Delivers** The `expiry` index with no row for never-expiring entries (D7); lazy expiry
in every read (`design.md` §9.1); `expire =` as seconds, `difftime`, `POSIXct`, `NULL` or
`Inf`; `stash_expire(n =)`; `stash_touch()`, `stash_add()`, `stash_pop()`,
`stash_incr()`, `stash_decr()`.

**Tests** Expired means absent to every reader before `stash_expire()` runs;
`stash_expire()` never changes an answer; `stash_add()` on an expired entry lands;
counters reject non-counters and values past ±2⁵³; eight `callr` processes incrementing
one key produce eight.

## S6 — Blobs — **M2**

The two orderings of `design.md` §8, and the stage the crash tests exist for.

**Delivers** Staging in `<root>/tmp/<pid>-<n>`, hashing, no `fsync` (a size check on read
instead; `design.md` §8), rename
into `blobs/<aa>/<hash>[.<ext>]` at mode `0444`; the `blobs` database with refcounts in
the same transaction as the record; commit-then-unlink on delete; `codec_file()` always
file-backed; `stash_path()`; `stash_volume()` from `mdbx_env_info()$file_size` plus
`bytes_blob`; `dastash_blob_corrupt` when a read finds its file missing. Windows:
existing rename targets, and clearing the read-only attribute before `unlink()`.

**Crash injection**: an environment variable that aborts the process between publishing
a blob and committing, and between committing a delete and unlinking.

**Freezes** the blob layout and `format_version = 1`: everything a store holds.

**Tests** Identical bytes are stored once and survive deleting one of two referrers; a
kill between publish and commit leaves at most an orphan; a kill between commit and
unlink leaves at most an orphan and never a dangling record; eight processes writing the
same key leave no partial file and every hash verifies; `stash_volume()` equals the sum
of encoded sizes after any sequence of writes and deletes.

## S7 — Size limit, tags and maintenance

**Delivers** The `stored` index and least-recently-stored eviction; `stash_cull()` in
bounded transactions of `cull_limit`; one bounded cull from `stash_set()` when over
`size_limit`; the `tags` index, `tags =` on writes (at most 16, each at most `TAG_MAX`);
`stash_evict(tag =)` and `stash_evict(prefix =)`; `stash_clear()`; `stash_info()`,
`stash_entries(prefix =, tag =, n =)`, `stash_stats()`; `stash_check(repair =, hash =)`
with every finding kind of `design.md` §11.3.

**Tests** The volume stays under the limit after any sequence of writes; one value
larger than the limit is stored and everything else is evicted around it; eviction by tag
and by prefix; every `stash_check()` finding produced deliberately and repaired; no index
row without a meta record, none missing, after a randomised sequence of mutations; one
writer and seven readers through a cull, no reader sees a dangling blob.

## S8 — Transactions and concurrency

**Delivers** `stash_transact()` on the environment's transaction (D21), with nesting and
blobs published before the record inside a block; the `durability` flags with `ACCEDE`
and the effective mode reported in `stash_stats()`; `dastash_forked` exercised through
`parallel::mcparallel()`.

**Tests** A block commits or aborts as a unit; reads inside a block see its writes; a
verb on a second handle inside a block joins it; an aborted block with blob writes leaves
at most orphans; a forked child gets `dastash_forked`; a joiner inherits the incumbent's
durability.

## S9 — Memoisation and cachem — **M3**

**Delivers** `stash_memoise()` with the `name/v<version>/canon(args)` key, defaults
filled in, `omit =`, `key =`, `name =`, `expire =`, `tags =`, `codec =`;
`stash_memoise_key()`, `stash_forget()`, `stash_forget_all()`, `is_stash_memoised()`;
`as_cachem()` with the `^[a-z0-9_-]+$` key rule; `length()`, `[[`, `[[<-`, `format()`,
`as.list()` with its limits.

**Tests** Positional and named calls agree; an omitted argument and its default agree;
an unkeyable argument raises with the hint; an anonymous function without `name` raises;
`stash_forget_all()` removes only that function's entries; eight processes calling one
memoised function get identical results with at least one computation;
`memoise::memoise(f, cache = as_cachem(s))` works; cachem's own conformance expectations
(miss returns `key_missing()`, `reset()`, `prune()`, `size()`).

## S10 — Release — **M4**

**Delivers**

- roxygen documentation for every export, each with `@return` and a runnable example
  that writes only under `tempdir()`, usually through `local_stash()`.
- `README.Rmd`: what the package is, installation, a short tour, and the deployment
  envelope.
- Vignettes: *Getting started* and *Operating a shared store* (processes, durability,
  size limits, `stash_check()`).
- pkgdown reference index grouped as in `design.md` §3.11.
- `NEWS.md`, `cran-comments.md`.
- The `cran-extrachecks` skill run over the package, and every finding resolved.

**Done when**

- `R CMD check --as-cran` gives 0 errors, 0 warnings and only the new-submission NOTE,
  locally and on the full CI profile (Linux, macOS, Windows, the `nosuggests` job).
- win-builder (release and devel) and mac-builder pass.
- The package is submitted, and accepted.

---

# 3. CRAN constraints that shape the stages

Collected here so no stage discovers them late.

- **Where tests write.** Only under `tempdir()`, and every test cleans up; `local_stash()`
  is the default fixture. No example writes to the home directory.
- **Time and cores.** CRAN allows at most two cores and a few minutes of check time. The
  `callr` multi-process suites and crash injection run in CI and are
  `skip_on_cran()`; a small smoke version (two processes, one key) runs everywhere.
- **Fork tests** are `skip_on_os("windows")`.
- **Windows.** `file.rename()` over an existing file, and read-only files before
  `unlink()`. PID liveness for `tmp_stale` needs no new dependency on Unix
  (`tools::pskill(pid, 0)`); the Windows equivalent is settled in S7. Symlinks matter only
  for `stash_tree()`, which is 0.2.0.
- **`mdbx` binaries.** CRAN builds from source, so `mdbx (>= 0.1.1)` is satisfied there.
  Users on a platform whose CRAN binary still lags need `type = "source"`; the README says
  so until the binaries catch up.
- **Suggests are optional.** Every use of `cachem`, `memoise`, `callr`, `withr` and
  `bit64` in tests and examples is guarded, which the `nosuggests` job proves.
- **Text.** Software names in `Title` and `Description` in single quotes (`'libmdbx'`,
  `'diskcache'`), no "for R" or "package" in the title, and URLs in angle brackets.

---

# 4. Design changes this plan makes

- **`#` joins the opener set** (`design.md` §5.2). Without it, a string key that is `#`
  followed by 64 hex characters is stored under the same bytes as a digested long key.
- **Build order** in `design.md` §18 now points here.
