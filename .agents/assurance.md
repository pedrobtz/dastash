# Assurance

How this package meets `.claude/shared/assurance.md`. CI checks this
file (r-actions `assurance.yml`), so keep the headings and table
columns as they are.

- **Statuses:** a cell is a fact, `gap #<issue>` or `n/a: <reason>`.
- **Evidence:** every fact names the test whose assertion carries it, read
  from the test, not from `design.md`.

## Kinds

`untrusted-input` `spec` `lifecycle` `emits`

Why each applies (no backticks here: the check reads every quoted word in
this section as a kind):

- untrusted-input: it decodes records (unserialize() in R/record.R), inline
  values, counter rows and blob files from a directory that other processes
  and other versions write, and that a crash or a user can damage;
  cache_check() exists for that.
- spec: the key encoding in inst/spec/key-encoding-v1.md, frozen by golden
  vectors; the ordered index encodings (design.md section 7.4); SHA-256.
- lifecycle: cache handles, the per-process environment registry and the
  transaction it owns, memoised closures, the as_cachem() adapter, staged and
  held files, and blob paths handed to the caller.
- emits: cache.mdbx, read by other R processes, and blob files that
  readRDS(), or any program given a codec_file() path, reads.

There is no src/ directory, so compiled does not apply.

## Required checks

`Where` names the workflow file under `.github/workflows/` that runs the
check. Add `(own)` when that workflow is the package's own rather than a
call to r-actions.

<!-- markdownlint-disable MD013 -->
| Check      | Status                                                                                                                                                                             | Where |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| fuzz       | n/a: r-actions `fuzz.yml` runs libFuzzer over a package's own C with no R in the loop, and dazcache has none. Its untrusted decoders are R; their corrupt-input oracles are the Boundaries rows below |       |
| fuzz-reach | n/a: a step of `fuzz.yml`, which has nothing to fuzz here (see `fuzz`)                                                                                                             |       |
<!-- markdownlint-enable MD013 -->

## Boundaries

One row per boundary the package crosses. An oracle knows the answer:

- a conformance suite or test vectors;
- a reference implementation;
- a round trip;
- equivalent inputs compared;
- the bytes the other side received.

"No crash" is not an oracle.

<!-- markdownlint-disable MD013 -->
| Boundary                                                          | Oracle                                                                                                                    | Carried by                                                                  |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| key encoding, value to canonical text                             | golden vectors (`canon` column of `golden/key-vectors.csv`) and literal texts for doubles, subnormals, times, latin1      | tests/testthat/test-key.R                                                   |
| key encoding, `Date` and `POSIXct` outside years 0000-9999        | golden vectors computed independently (Python `datetime` shifted by 400-year cycles, exact fractions); R's `POSIXlt` fields as the reference within 0000-9999 | tests/testthat/test-key.R |
| key encoding under a hostile session                              | the golden vectors under `LC_ALL=C` and `options(OutDec = ",", scipen = -5, digits = 3)`                                  | gap #67                                                                   |
| key encoding, equivalent values                                   | equivalent inputs compared: `1L` and `1`, `-0` and `0`, field order, time zone, `integer64`; distinct inputs differ       | tests/testthat/test-key.R                                                   |
| key encoding, doubles as `%a`                                     | reference implementation: R's parser reads each text back to the identical double, 550 random values with subnormals      | tests/testthat/test-key.R                                                   |
| key encoding, `±2^53` as an integer                               | golden vectors at exactly `±2^53` and `±(2^53 + 2)`                                                                       | gap #92                                                                   |
| key encoding, a digested key with attributes or a class           | one entry under both spellings; `cache_key()` of both identical                                                           | tests/testthat/test-key.R |
| key encoding, classed lists and malformed classed values          | a key text or `dazcache_key_invalid`, never another class                                                                 | tests/testthat/test-key.R |
| `prefix` under a non-UTF-8 session                                | the same keys as in a UTF-8 session, for every prefix-taking verb                                                         | tests/testthat/test-key.R |
| a namespace prefix (`cache_forget_all()`, `as_cachem(prefix =)`)  | only the namespace's keys, beside user keys that extend the prefix                                                        | tests/testthat/test-memoise.R, tests/testthat/test-interop.R |
| key text back to a key (`cache_key_text()`)                       | round trip: every listed key reads its value back                                                                         | tests/testthat/test-key.R, tests/testthat/test-cache.R                      |
| stored key and `#<sha256>` digest                                 | golden vectors (`stored` column); the preview is valid UTF-8 and not split mid-character                                  | tests/testthat/test-key.R                                                   |
| SHA-256 (`hash_bytes()`, `hash_text()`, `hash_file()`)            | FIPS 180-2 test vectors; `hash_file()` and `hash_bytes()` compared                                                        | tests/testthat/test-hash.R                                                  |
| blob name and path `blobs/<aa>/<sha256>.<ext>`                    | the name is the file's SHA-256, its directory the first two hex digits, its mode 0444                                     | tests/testthat/test-blob.R                                                  |
| rds blob file, read by another program                            | the bytes the other side received: `readRDS(path)` is identical to the value                                              | tests/testthat/test-blob.R                                                  |
| raw blob file, read by another program                            | the bytes the other side received: `readBin(path)` equals `charToRaw(enc2utf8(x))`                                        | tests/testthat/test-codec.R                                                 |
| codecs `raw`, `rds`, `file` and user codecs, decoding             | round trip through a real file                                                                                            | tests/testthat/test-codec.R                                                 |
| rds inline bytes against `saveRDS()` file bytes                   | `serialize(version = 3)` compared with an uncompressed `saveRDS()` file, as `R/codec.R` claims                            | gap #68                                                                   |
| `codec_rds(compress = TRUE)`                                      | round trip, inline and as a file                                                                                          | tests/testthat/test-codec.R                                                 |
| decode dispatch on the recorded codec                             | an unknown or newer codec raises its class; a value reads back under another default codec                                | tests/testthat/test-codec.R, tests/testthat/test-cache.R                    |
| two codecs under one name, and codec parameters across a reopen   | refused, or each entry reads back its own value; a reopened cache writes as configured                                    | gap #120                                                                    |
| a user codec's meta, read for the blob name                       | the blob name follows the documented rule for meta `ext`, `extra` and `extension`                                         | gap #118                                                                    |
| a user codec that writes a directory, a symlink or nothing        | `dazcache_codec_error`, and `tmp/` empty                                                                                   | gap #119                                                                    |
| a user codec that decodes to a path, inline and as a blob         | the returned path exists and holds the bytes                                                                              | gap #121                                                                    |
| counter row, int64 big-endian two's complement, encoding          | literal bytes for -1 and 1                                                                                                | tests/testthat/test-expire.R                                                |
| counter row, encoding at ±2^31, ±2^32 and ±2^53                   | literal bytes                                                                                                             | gap #69                                                                   |
| counter row, decoding                                             | round trip over 11 values; 8 processes give 8 increments                                                                  | tests/testthat/test-expire.R                                                |
| counter row that is not 8 bytes                                   | a classed error, not a value                                                                                              | gap #100                                                                   |
| `enc_f64()` and `enc_u64()` ordered encodings                     | byte order equals numeric order over 517 values with ±Inf, ±0 and subnormals; mdbx sorts them the same              | tests/testthat/test-encode.R, tests/testthat/test-engine.R                  |
| `enc_f64()` and `enc_u64()`, the bytes on disk                    | literal bytes, `INDEX_ENCODING_VERSION` 1                                                                                 | gap #70                                                                   |
| `enc_f64()` and `enc_u64()`, decoding                             | round trip                                                                                                                | tests/testthat/test-encode.R                                                |
| index rows `expiry`, `stored`, `tags`, decoding                   | behaviour: eviction order, evict by tag removes exactly the tagged keys, orphan tag rows end the walk, expiry reclaims     | tests/testthat/test-maintain.R, tests/testthat/test-expire.R                |
| index rows, the bytes on disk                                     | literal row bytes for one known entry (today `store_violations()` compares them with `index_rows()`, the code under test) | gap #71                                                                   |
| orphan or stale `expiry` and `stored` rows                        | the expire and evict walks return, drop the rows and delete no live entry                                                 | tests/testthat/test-maintain.R |
| prefix scan in chunks (`engine_scan()`)                           | expected key lists across chunk boundaries, inclusive start, `n`, digested keys                                           | tests/testthat/test-engine.R, tests/testthat/test-maintain.R                |
| `meta`, `blobs`, `counters`, `format` and `config` records        | round trip across a reopen; a newer format version is refused                                                             | tests/testthat/test-cache.R                                                 |
| records written by 0.1.0, read by a later version                 | a checked-in 0.1.0 fixture store read back                                                                                | gap #72                                                                   |
| torn or garbage record                                            | a `dazcache_*` error from reads, and a finding from `cache_check()`                                                       | gap #98                                                                   |
| garbage inline value bytes                                        | `dazcache_codec_error` with the key                                                                                       | gap #73                                                                   |
| inline value missing, or not `record$bytes` long                  | a classed error from reads, and a finding from `cache_check()`                                                            | gap #113                                                                    |
| blob file from disk, decoding                                     | a missing or wrong-size file raises `dazcache_blob_corrupt` with `path`; a same-size flip is found by `cache_check(hash = TRUE)` | tests/testthat/test-blob.R, tests/testthat/test-maintain.R             |
| same bytes written over a damaged or missing blob                 | both keys read back the value                                                                                             | gap #114                                                                    |
| crash windows: publish, commit, unlink                            | the state after `SIGKILL`: no record, one orphan file, and `cache_check()` reports exactly `blob_orphan`                   | tests/testthat/test-blob.R, tests/testthat/test-transact.R                  |
| `cache_check()` on a damaged store                                | expected finding kinds for injected damage; after repair no findings, `store_violations()` empty, values intact           | tests/testthat/test-maintain.R                                              |
| `cache_check(repair = TRUE)` on combined row and file damage      | one repair, then `cache_check(hash = TRUE)` is empty                                                                      | gap #116                                                                    |
| `cache_check()` on a blob in the wrong directory                  | a `blob_missing` and a `blob_orphan` finding                                                                              | gap #99                                                                   |
| `cache.mdbx` read by another R process                            | round trip across `callr` processes in both directions                                                                    | tests/testthat/test-cache.R, tests/testthat/test-blob.R                     |
| the whole store under a random sequence of operations             | a model: an R list of key to value compared with `cache_get()` and `cache_keys()` after each step                         | gap #74                                                                   |
| `as_cachem()`                                                     | a real consumer: `memoise::memoise()` computes once; the cachem semantics of `key_missing`, `keys` and `reset`            | tests/testthat/test-interop.R                                               |
| `as_cachem()` against `cachem::cache_mem()`                       | one operation script run on both, results compared                                                                       | gap #75                                                                   |
| memoised call to key                                              | equivalent calls compared: positional, named and default arguments are one key; `omit`, `version` and `name` change it   | tests/testthat/test-memoise.R                                               |
<!-- markdownlint-enable MD013 -->

## Objects

One row per object that outlives the call that made it. "Sequences" is
the test of its out-of-order use (abort then read, use after end, use
after free). The guard columns name the test, or say why the guard
cannot apply.

<!-- markdownlint-disable MD013 -->
| Object                                       | Sequences                                                                                                                 | Fork                                                                           | Unwind                                                                                             | Owner                                                                                             |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| cache handle (`dazcache_cache`)              | test-cache.R "closing is idempotent, and a closed cache refuses verbs", "two handles on one directory share it and close separately" | gap #76                                                              | gap #77                                                                                          | gap #102                                                                                         |
| environment registry entry                   | test-engine.R "a second open in this process shares the environment, under any spelling", "a read-only open cannot be joined for writing" | gap #96                                                           | test-engine.R "an error in a write aborts it and passes through unchanged"                         | gap #78                                                                                         |
| write transaction, `cache_transact()`        | test-transact.R "nested blocks and other handles join the transaction", "leaving a block with return(), break or next commits it" | gap #76                                                               | gap #79                                                                                          | gap #97                                                                                         |
| write transaction spanning two caches        | gap #80                                                                                                                 | gap #76                                                                      | gap #80                                                                                          | n/a: each cache's own transaction, as above                                                       |
| write transaction with a signalled, handled error | gap #124                                                                                                     | n/a: as the write transaction above                                            | gap #124                                                                                           | n/a: as the write transaction above                                                               |
| cache handle after another writer is killed       | gap #122                                                                                                     | n/a: the killed writer is another process                                      | gap #122                                                                                           | gap #122                                                                                          |
| cache handle across `unloadNamespace()` and reload | gap #123                                                                                                    | n/a: one process                                                               | n/a: no frame unwinds                                                                              | gap #123                                                                                          |
| registry entry over a deleted directory           | gap #126                                                                                                     | n/a: one process                                                               | n/a: no frame unwinds                                                                              | gap #126                                                                                          |
| read transaction (`engine_read()`)           | test-engine.R "a write inside a read transaction is an internal error"                                                    | test-engine.R "a forked child cannot use an inherited environment"             | gap #79                                                                                          | its `engine_read()` frame, `on.exit()`                                                            |
| memoised function (`dazcache_memoised`)      | test-memoise.R "a memoised function on a closed cache says so"                                                            | gap #76                                                                      | test-memoise.R "a result the cache cannot store is returned, with a warning"                       | n/a: holds the handle and owns nothing; the caller closes the cache                               |
| `as_cachem()` adapter                        | gap #81                                                                                                                 | gap #76                                                                      | n/a: holds no resource, only the handle                                                            | n/a: holds the handle and owns nothing; the caller closes the cache                               |
| `local_cache()` and `with_cache()` handles   | test-cache.R "local_cache() closes on exit and deletes its temporary directory", "with_cache() passes the cache to a function and closes it" | gap #76                                                   | gap #82                                                                                          | test-cache.R "local_cache() closes on exit and deletes its temporary directory"                   |
| staged file `<root>/tmp/<pid>-<n>`           | test-blob.R "staging leaves nothing behind"                                                                               | test-maintain.R "stale staging files of dead processes are reported and removed" | test-maintain.R "an encoder that fails or is interrupted leaves no staging file"; after staging, gap #83 | `cache_prepare()` `on.exit()`, then the caller's `unstage()`; test-blob.R "staging leaves nothing behind" |
| file held by `cache_pop()`                   | gap #95                                                                                                                 | test-maintain.R "stale staging files of dead processes are reported and removed" | gap #83                                                                                        | test-expire.R "cache_pop() reads a shared file it releases, and leaves nothing staged"            |
| staging name reused after a crash (same PID)      | gap #127                                                                                                     | gap #127                                                                       | n/a: as the staged file above                                                                      | gap #127                                                                                          |
| blob file mode 0444                               | gap #125                                                                                                     | n/a: a file on disk                                                            | gap #125                                                                                           | gap #125                                                                                          |
| blob path returned to the caller             | test-blob.R "codec_file() stores a copy, with its extension, even when small"; test-memoise.R "a file-backed result is the same path on a miss and a hit" | n/a: a read-only file named by its content; nothing per process            | n/a: the caller holds a string, nothing to release                                                 | test-transact.R "a committed block unlinks what it released, after the commit"                    |
<!-- markdownlint-enable MD013 -->

## Limits

One row per limit the package enforces. "Straddled by" is the test of
`limit - 1`, `limit` and `limit + 1` on every path that reaches it.

<!-- markdownlint-disable MD013 -->
| Limit                                         | Unit                                                    | Straddled by                                                                                                |
| --------------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `KEY_MAX` (512)                               | UTF-8 bytes of the canonical key text                   | gap #84                                                                                                   |
| `CANON_KEEP_MAX` (4096)                       | UTF-8 bytes of the canonical key text                   | gap #85                                                                                                   |
| `KEY_PREVIEW_MAX` (256)                       | UTF-8 bytes, cut back to a character boundary           | gap #129                                                                                                    |
| `TAG_MAX` (256)                               | UTF-8 bytes of one tag                                  | gap #86                                                                                                   |
| 16 tags per entry                             | distinct tags, after `unique()`                         | gap #86                                                                                                   |
| `inline_max`                                  | encoded value bytes (codec output), `>=` makes a file   | gap #87                                                                                                   |
| `size_limit`                                  | encoded bytes held: inline values plus each blob once   | gap #88                                                                                                   |
| `size_limit` on counter writes                | encoded bytes held                                      | gap #117                                                                                                    |
| `cull_limit`                                  | entries per transaction                                 | gap #94                                                                                                   |
| memoise `version`                             | whole number, up to `.Machine$integer.max`              | gap #112                                                                                                    |
| `COUNTER_MAX` (2^53)                          | absolute counter value                                  | gap #93                                                                                                   |
| ordered count, `[0, 2^53]`                    | whole doubles                                           | tests/testthat/test-encode.R: `2^53` accepted, `2^53 + 2` and `-1` refused                                  |
| `CODEC_META_MAX` (4096)                       | bytes of the encoded codec meta                         | gap #89                                                                                                   |
| `ENGINE_SCAN_CHUNK` (1000)                    | keys per `mdbx_keys()` call                             | gap #130                                                                                                    |
| `timeout`                                     | seconds, wall clock                                     | n/a: a wall-clock bound has no limit - 1; tested at 0, 0.3 and 30 s with a holder released before and after (test-engine.R, test-transact.R) |
| `BLOB_REAP_TIMEOUT` (5)                       | seconds                                                 | gap #90                                                                                                   |
| key and tag rows against mdbx's key size      | bytes, at the smallest page size                        | tests/testthat/test-key.R "limits fit the smallest page size"; tests/testthat/test-engine.R (`keysize_max + 1`) |
| mdbx's value size                             | bytes of one inline value                               | gap #91                                                                                                   |
| `map_size`                                    | bytes of `cache.mdbx`                                   | n/a: mdbx grows the map in steps, so no byte boundary can be aimed at; a full map is tested in test-maintain.R "a write that fills the map leaves the cache sound and usable" |
| `display_key()` (80)                          | characters                                              | n/a: shortens keys in messages only, nothing stored or compared                                             |
<!-- markdownlint-enable MD013 -->
