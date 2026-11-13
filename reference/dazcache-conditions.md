# Conditions raised by dazcache

Every error dazcache raises inherits from `dazcache_error`, and from
exactly one class that says what went wrong. Catch the specific class to
tell "compute it again" apart from "the store is broken":

|  |  |
|----|----|
| Class | Raised when |
| `dazcache_key_invalid` | An object the key encoding does not cover; a partially named vector; an anonymous memoised function without `name` |
| `dazcache_not_found` | A read of an absent or expired key without `default`; [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md) with `create = FALSE` on a missing directory |
| `dazcache_type_error` | A counter operation on a non-counter or past 2^53; a path or lazy read of an entry of the wrong shape; a value a codec cannot store; an `expire` that is `NA` or `NaN` |
| `dazcache_codec_error` | Encoding or decoding failed; a codec's package is not installed; a record names a codec the handle does not know |
| `dazcache_blob_corrupt` | A read finds the file behind a record missing, or not the size its record holds |
| `dazcache_busy` | The write lock was not acquired within `timeout` |
| `dazcache_store_full` | The database reached its `map_size` |
| `dazcache_readonly` | A write on a read-only handle |
| `dazcache_config_conflict` | An explicit store-level setting disagrees with the stored one |
| `dazcache_version_unsupported` | The store was written by a newer format or key encoding |
| `dazcache_forked` | A handle used in a process that did not open it |
| `dazcache_closed` | A verb on a closed handle |
| `dazcache_unsupported` | The platform or this release cannot do it |
| `dazcache_engine_error` | Any other failure of the storage engine, with the original condition as `parent` |

Conditions carry structured fields where they apply, such as `key`,
`dir`, `path` and `codec`, so a handler can act on them without parsing
the message.

dazcache raises one warning, of class `dazcache_memoise_unstored` and
`dazcache_warning`: a memoised function computed a result but the cache
was busy, full or read-only, so it was returned without being stored.
Its `parent` is the error that prevented storing it.
