# Review of the dastash design documents

**Date:** 2026-09-10. **Scope:** the six documents in the repository as of commit `6e269b1`,
against the brief: *a disk store/cache for R, inspired by Python's `diskcache`, usable the
way `polars-diskcache` is used, with an API natural to the R ecosystem.*
**Outcome:** `design.md` rewritten as v2; the previous contract kept as `design-v1.md`.
Section references below in the form `v1 §N` point at `design-v1.md`; `§N` alone points
at the new `design.md`.

---

# 1. Verdict

The storage design in v1 is sound and should be kept almost verbatim: the publish and
delete orderings, content addressing with transactional refcounts, derived indexes,
order-preserving encodings, lazy expiry, the read journal, the configuration split and
the error taxonomy are all correct and well argued, and `cache-model.md` turns most of
them from advice into theorems. Nothing in the review found a soundness problem in the
storage layer.

Three things needed redefining. **The API** was an R6 method surface that
`functional-api.md` had already argued against convincingly and the brief now asks to
replace; the documents disagreed about miss semantics, expiry arguments, tags and
constructors, and one of them had to win. **The `polars-diskcache` half of the brief was
under-served**: v1 stored Parquet and handed out paths, but laziness was not preserved
through the cache, the browsable tree was noted as "worth an entry in §16" and never
designed, and per-argument key control existed only for the typed layer. **Several
smaller decisions were wrong for a cache** even though they were right for a typed store:
rejecting doubles as keys, requiring NFC normalisation that base R cannot do, raw keys
that cannot be printed, indexing `Inf` deadlines, and a `bit64` dependency for counters.

The rest is verification: the engine is not on CRAN, its API was checked against the
repository rather than the vignette, and the design now records what it actually
provides.

---

# 2. What holds

Kept unchanged in v2, with the section that carries it:

| v1 | Now | Why it holds |
|---|---|---|
| v1 §7 blob first, commit second; commit first, unlink second | §8 | Forced by the inclusion `ran(M) ⊆ dom(B)`; `cache-model.md` §11.3 |
| v1 §6.1 content-addressed blobs with refcounts in the same transaction | §6.1, §8 | A refcount kept outside the records can disagree with them |
| v1 §4 never hash `serialize()`; frozen, versioned key encoding; golden vectors | §5.2 | The cost of getting it wrong is paid after an R upgrade |
| v1 §3.3 indexes are derived and rebuildable; key encoding is not | §7.5 | Makes `check(repair = TRUE)` possible |
| v1 §5 `enc_f64` with sign-bit transform | §7.4 | Plain big-endian sorts `-1` above every positive |
| v1 §4.1 `KEY_MAX`, `TAG_MAX` as constants, not page-derived | §5.3 | A macOS-written store must open on Linux |
| v1 §8.3 lazy expiry; reads are read transactions | §4, §9.1 | Expiry lives in the observation, not the state |
| v1 §9.3 batched access journal; LRS default | §9.3, D4 | Eviction accuracy is not a correctness property |
| v1 §8.1 store-level vs handle-level settings; `dastash_config_conflict` | §12 | Two processes disagreeing about `inline_max` cannot share a store |
| v1 §11.1 durability default `safe`; `fast` is `SAFE_NOSYNC` | §11.1 | Crash under relaxed sync ≈ eviction; corruption is a different kind |
| v1 §12 classed conditions via `rlang::abort()` | §13 | Callers distinguish "recompute" from "broken" |
| v1 §0 deployment: many processes, one host, local filesystem | §0 | `dastash-design.md` §5.1–§5.2's premise was wrong and stays corrected |
| v1 §10 fork safety, `TRY` plus backoff, short read transactions | §10 | Verified against `mdbx`'s concurrency topic |
| v1 §17 typed layer later, in this package, as a layer | §20, D19 | A schema constrains canonicalisation; it does not replace it |

---

# 3. Findings

Each finding names where it was, what was wrong or missing, and what v2 does.

## 3.1 The API

**F1 — Two documents, two APIs.** `design-v1.md` §8 specifies `s$get()`, `s$set()` on an
R6 object; `functional-api.md` specifies `stash_get(s, …)` and says "nothing here changes
the contract". A reader cannot tell which to implement, and `CLAUDE.md` names R6 an
invariant. The brief asks for an R-natural API, and the functional document's case is
right: methods do not pipe, do not pass to `lapply()`, and are invisible to `methods()`
and the NAMESPACE. **v2: functions are the API (§2, §3, D1); the handle is an environment
with an S3 class and R6 leaves `Imports` (D2).**

**F2 — Miss semantics disagreed three ways.** v1 §8.2: `get(key, default = NULL)`; v1
§8.3: `[[` raises; `functional-api.md` §5: error unless `default` is supplied. `NULL` is
a legal cached value, so `default = NULL` conflates a stored `NULL` with a miss. **v2:
`missing(default)` decides (§3.3, D3).**

**F3 — Expiry arguments.** v1 took seconds; `functional-api.md` added `expire_in()`,
`expire_at()`, `expire_never()` and left it open (its Q4). R already has `difftime` and
`POSIXct`. **v2: `expire =` takes a number, a `difftime`, a `POSIXct`, `NULL` or `Inf`
(§3.4, D8).**

**F4 — Constructors for enumerations.** `functional-api.md` rule 7 made `evict_lru()` a
value. Eviction and durability are closed choices; `match.arg()` strings are the R idiom
for those, and `diskcache`'s names are what users will search for. **v2: strings for
enumerations, objects for behaviour (D10).**

**F5 — Data-masked predicates in `stash_entries()`.** `functional-api.md` §7 proposed
`stash_entries(s, tag == "XSWX")` with pushdown for three columns. Recognising which
quosures map to which index is a query planner, and the fallback is a full scan the user
did not ask for. **v2: two explicit indexed filters, `prefix` and `tag`; `dplyr` for the
rest (§3.5, D11).**

**F6 — Plural names.** `functional-api.md` used `stash_get_many()`/`stash_set_many()`.
Base R's name for "get several into a named list" is `mget()`. **v2: `stash_mget()`,
`stash_mset()` (§3.3, §3.4).**

**F7 — `stash_size()` is ambiguous** between bytes and entries. **v2: `stash_count()`
and `stash_volume()`; `length()` is the former.**

**F8 — Memoisation naming.** v1 `s$memoise()`, `functional-api.md` `stashed()` with
`stashed_key()`/`stashed_forget()`. The adverb name breaks the prefix and hides the
relationship to `memoise::memoise()`, which is the function R users know. **v2:
`stash_memoise()`, `stash_memoise_key()`, `stash_forget()`, `stash_forget_all()` (§3.8).**
`memoise`'s `omit_args` arrives as `omit =`, which neither v1 document had.

**F9 — No `dastash_closed`.** v1 §12 had no class for a verb on a closed handle. **v2:
added (§13).**

**F10 — A second `stash()` on the same directory in one process was unspecified.**
libmdbx must not open one environment twice in a process. **v2: a process-local registry
returns a handle sharing the environment; the environment closes with the last handle
(§3.1).**

## 3.2 The `polars-diskcache` half of the brief

**F11 — Laziness was not preserved.** `prior-art-diskcache.md` §7.2 identifies frame-type
preservation as "the point of the library rather than a convenience", and
`cache-model.md` §16 names it as outside the model. v1 offered `path()` and
`arrow::open_dataset()` by hand; `functional-api.md` added `stash_lazy()` for explicit
reads. Neither made a memoised function that returns an arrow query return a scan on a
hit. **v2: the record carries a `shape`; a lazy frame in is a lazy scan out from
`stash_get()` and from memoised functions; `stash_lazy()` covers eager entries and other
engines; DuckDB's asymmetry is stated (§6.4, D15).**

**F12 — The browsable tree was never designed.** `prior-art-diskcache.md` §8 called it
"the idea worth stealing" and "worth an entry in §16"; v1 §16 does not mention it. **v2:
`stash_tree()`, derived and on demand, with the path-from-key rules, the memoised
`name=value` expansion, relative symlinks, and the Windows failure mode (§6.6, D16).**

**F13 — `cache_key=` had no equivalent in the cache.** v1 §8.3's `memoise()` had `version`
only; the argument-exclusion callback lived in `functional-api.md` §10. **v2: `key =` and
`omit =` on `stash_memoise()` (§3.8, D17).**

**F14 — Parquet engine unspecified.** v1 §6.2 said "arrow or nanoparquet" without saying
which writes, which reads, or what is recorded. `nanoparquet` 0.5.1 (CRAN, 2026-04-20)
writes data frames with no system dependency and cannot write arrow objects or read
lazily; `arrow` can do both. **v2: an engine table, `"auto"` rules, the writer recorded
in the codec field, and an explicit list of what Parquet does not round-trip (§6.3).**

**F15 — `stash_memoise()` keys and the tree had to agree.** For the tree to expand
arguments into directories, the memoised key must be a string with a recognisable
argument suffix. **v2: `<name>/v<version>/<canon of the matched arguments>` (§3.8), which
also gives prefix eviction and `stash_forget_all()` for free.**

## 3.3 Keys

**F16 — Doubles rejected.** v1 §4 rejected doubles "without a declared precision". Right
for a typed store; hostile for a cache whose keys are memoised function arguments. C99
hex floats (`sprintf("%a")`) are exact, portable and locale-free, and a double that is
whole and within ±2⁵³ can still encode as an integer so `1L` and `1` agree. **v2: doubles
accepted and exact (§5.2, D12).**

**F17 — NFC normalisation needs a dependency v1 did not list.** Base R has no
normaliser; `stringi` is ICU and `utf8` is another import. A cache miss is the entire
cost of not normalising. **v2: none in the core; `utf8::utf8_normalize()` documented for
callers who need it (§5.1, D12).**

**F18 — Raw keys.** v1 §4 accepted raw vectors as keys, which made `keys()` unable to
return a character vector. No R use case needs them. **v2: removed (§5.1, D12).**

**F19 — Ambiguity between a string key and a canonical key.** v1 stored strings as their
bytes and structured keys as `name=tag:payload` text in the same key space, so a string
key that happened to look like an encoding collided with a structured one. **v2: the
grammar reserves a set of openers; a top-level string starting with one is tagged
`s:`; all other strings are themselves (§5.2).** `stash_get(s, "k")` and
`stash_get(s, stash_key("k"))` are the same entry.

**F20 — The grammar covered only named lists of scalars.** Memoised arguments include
vectors, `NULL`, unnamed lists and data frames. **v2: a recursive grammar over a closed
set of types, everything else `dastash_key_invalid` with a hint (§5.2).** This is the
right place to fail: silently keying on a connection object is the failure
`polars-diskcache`'s `repr` keys have.

**F21 — Digested keys kept the full canon in the record.** A memoised call with a
megabyte vector would put a megabyte in `meta`. **v2: kept up to `CANON_KEEP_MAX`
(4 KiB), a preview and the length beyond (§5.3).**

## 3.4 Storage details

**F22 — `expire = Inf` was indexed.** One index write per never-expiring `set()` for rows
the scan can never reach. **v2: no row (§7.2, D7).**

**F23 — One tag per entry.** The index is one row per (tag, key) either way. **v2: a
character vector, at most 16 (§3.4, D9).**

**F24 — Counters returned `integer64`.** That put `bit64` in `Imports` for a value no
cache counter reaches. **v2: doubles, 64-bit storage, `bit64` to `Suggests` (D6).**

**F25 — `get(codec =)`.** v1 §8.2 let a read override the codec, contradicting v1 §3.2's
"decode dispatches on the recorded codec". **v2: no codec argument on any read.**

**F26 — User-defined codecs had no path to being read back.** The record names a codec;
a fresh process must know it. **v2: `codec()` constructor and `stash(codecs =)` per
handle; an unknown name is `dastash_codec_error` (§6.2).**

**F27 — `codec_auto()` could have picked a `Suggests` codec.** Not stated either way in
v1. If it depended on what the writer had installed, portability of the store would too.
**v2: never (§6.2).**

**F28 — Windows.** v1 did not mention that `file.rename()` fails when the target exists,
that read-only files must be un-marked before `unlink()`, or that symlinks may be
unavailable. **v2: §8 and §6.6.**

**F29 — `plan.md`'s engine abstraction was dropped entirely.** `plan.md` wanted `storr`'s
driver contract and a filesystem driver so v1 would not block on a binding that did not
yet exist; v1 then coupled to `mdbx` throughout. The binding exists and is first-party,
which settles it: no driver contract, no fallback engine, and a gap in the binding is a
feature request against `mdbx`. What survives is isolation — every `mdbx_*` call in one
file, where the error translation and the `TRY` loop live and where a fake engine can
stand in for unit tests. **v2: §14.2, §15, D14.**

## 3.5 Documents

**F30 — `CLAUDE.md` did not list three of the six documents** (`cache-model.md`,
`functional-api.md`, `prior-art-diskcache.md`). Updated.

**F31 — `plan.md` §0 assumes `mdbx_estimate_range()` and `mget`/`mput`**, which do not
exist. Already flagged by v1 §13; restated in §15 so it is not inherited.

**F32 — `dastash-design.md` §5.1–§5.2 derive the architecture from a wrong deployment
premise** (Azure Files, blobfuse). Already corrected by v1 §0; unchanged.

**F33 — `?mdbx-concurrency` says two environments opened on the same file in one session
are independent.** Running the build, the second open fails with `EAGAIN` whatever the
flags. Filed as [pedrobtz/mdbx#2](https://github.com/pedrobtz/mdbx/issues/2); it makes
`design.md` §3.1's per-process registry mandatory rather than prudent.
**Fixed** in [#4](https://github.com/pedrobtz/mdbx/pull/4), verified 2026-09-13: the
sentence is gone and the second open is refused by name. The registry stays mandatory —
it is there to share the environment, not to get a better error.

**F34 — `mdbx` errors have no condition classes.** A libmdbx failure is a `stop()` string
ending in `(mdbx error N)`; the binding's own refusals carry no code at all. dastash
cannot catch `MDBX_BUSY` or `MDBX_MAP_FULL` by class and must parse both shapes in one
place until `mdbx` 0.2 adds classes; that is the first item in `design.md` §15's asks.
Not filed as an issue: it is a feature request, not a defect.
[#4](https://github.com/pedrobtz/mdbx/pull/4) added three more suffix-less refusals
(2026-09-13), which makes the ask more valuable rather than less.

**F35 — `mdbx_dbi_open()` surfaces raw libmdbx text** for a missing database
("No matching key/data pair found") and for `create = TRUE` in a read transaction
("Permission denied"), against the package's own convention of naming the conflict.
Filed as [pedrobtz/mdbx#3](https://github.com/pedrobtz/mdbx/issues/3).
**Fixed** in [#4](https://github.com/pedrobtz/mdbx/pull/4), verified 2026-09-13: both name
the conflict, as does the same refusal reached through a stale `db` handle. The issue's
third suggestion — a missing database returning `NULL` — was deliberately not taken;
`mdbx_dbi_list()` answers that question in one call and `design.md` §7.2 now uses it.

---

# 4. Facts verified on 2026-09-10

`mdbx` was cloned to `../mdbx` (build `6521821`, the commit after the CRAN submission),
compiled, installed into the user library and exercised from R. Rows marked *run* come
from that; the rest from reading the source or the web.

| Claim in the documents | How | Result |
|---|---|---|
| `mdbx` 0.1.0 "submitted to CRAN" | CRAN page; repository log | Not on CRAN; commit `f7c635e` is the submission |
| `mdbx` exists at `../mdbx` | filesystem | Absent before; cloned and installed now |
| `mdbx` exports | `NAMESPACE` | 28 exports; no cursors, batch calls or `DUPSORT` |
| `mdbx_txn_begin(flags = "TRY")` fails rather than blocks | run, two processes | `MDBX_BUSY: Another write transaction is running … (mdbx error -30778)`, immediately; without `TRY` the call waited 3 s for the writer and then succeeded |
| One live transaction per environment | run | "already has an open transaction; commit or abort it before beginning another" |
| Two environments on one file in one process are independent (`?mdbx-concurrency`) | run | **False.** The second open fails with `Resource temporarily unavailable (mdbx error 35)`, with or without `ACCEDE`, read-only included |
| `ACCEDE` makes a joiner inherit the incumbent's sync flags | run, two processes | Confirmed; without `ACCEDE` the joiner gets `MDBX_INCOMPATIBLE (-30784)` |
| `mdbx_keys(start =)` is inclusive; no upper bound | run | `start = "a/"` yields `a/1 … b/2 k1`: positions at the first key at or after `start` and keeps going |
| `keysize_max` 2022 at 4 KiB, 8166 at 16 KiB | run | Confirmed; a 2023-byte key is `MDBX_BAD_VALSIZE`; the empty key stores |
| Named databases open in read transactions | run | Existing ones yes; `create = TRUE` in a read transaction is `Permission denied (mdbx error 13)`; a missing one is `MDBX_NOTFOUND` |
| `mdbx_put(overwrite = FALSE)` | run | Returns `FALSE` on an existing key; `mdbx_del()` returns whether a record existed; `mdbx_get()` takes `default` |
| `MDBX_MAP_FULL` on exhaustion | run, 1 MiB map | `MDBX_MAP_FULL: Environment mapsize limit reached (mdbx error -30792)`; `mdbx_env_info()` has `geo_upper`, `geo_current`, `mapsize`, `file_size` |
| Errors carry condition classes | source, run | No. Plain `stop()` strings ending in `(mdbx error N)` |
| `mdbx_env_stat(txn, db =)$entries` exact | source, run | Yes, within the transaction; usable for `stash_count()` |
| The vignette's `be8()` is plain big-endian and unlinks inside the transaction | `cache.Rmd` | Confirmed, and the vignette says so itself |
| `nanoparquet` writes data frames, no system dependency | CRAN, 0.5.1 | Confirmed; nested lists unsupported |
| R `polars` on CRAN | CRAN | Archived 2023; not a declarable dependency |
| `memoise` keys by `rlang::hash()` | local, 2.0.1 | Confirmed; `hash = function(x) rlang::hash(x)` |
| `cachem` key rule | local, 1.1.0 | `^[a-z0-9_-]+$`; `.` and upper case rejected; miss is `key_missing()` |
| `tools::sha256sum()` in R 4.5 | local, 4.5.2 | Present; `sha256sum(files, bytes)`, the two exclusive |
| `sprintf("%a")` exact and portable | local | `0.1` → `0x1.999999999999ap-4`; `-0` → `-0x0p+0`, normalised to `i:0` |

Two of these change the design rather than confirm it: the failed second open makes the
per-process environment registry in `design.md` §3.1 mandatory (F33), and the absence of
condition classes puts an error-message parser in `R/engine.R` until `mdbx` 0.2 removes
the need (F34; `design.md` §13, §15).

**Two rows were superseded on 2026-09-13.**
[pedrobtz/mdbx#4](https://github.com/pedrobtz/mdbx/pull/4) fixed F33 and F35, so the
second open and the named-database rows now give refusals that name the conflict rather
than `mdbx error 35`, `mdbx error 13` and `MDBX_NOTFOUND`. The table is left as it was
run: it records build `6521821`, which is the code submitted to CRAN. `design.md` §15
carries the current behaviour.

---

# 5. What changed in the repository

```text
design.md           rewritten: the v2 contract
design-v1.md        the previous design.md, with a superseded header
review.md           this file
functional-api.md   header added: absorbed into design.md §3
CLAUDE.md           rewritten to match
../mdbx             cloned from github.com/pedrobtz/mdbx and installed into the user
                    library with R CMD INSTALL, so the design could be run against it
```

`cache-model.md`, `prior-art-diskcache.md`, `dastash-design.md` and `plan.md` are
untouched; their `design.md §N` citations now mean `design-v1.md §N`, and `design.md` §0
gives the mapping.
