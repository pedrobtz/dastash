# Conditions raised by dastash

Every error dastash raises inherits from `dastash_error`, and from
exactly one class that says what went wrong. Catch the specific class to
tell "compute it again" apart from "the store is broken":

|  |  |
|----|----|
| Class | Raised when |
| `dastash_key_invalid` | An object the key encoding does not cover; a partially named vector; an anonymous memoised function without `name` |
| `dastash_not_found` | A read of an absent or expired key without `default`; `stash()` with `create = FALSE` on a missing directory |
| `dastash_type_error` | A counter operation on a non-counter or past 2^53; a path or lazy read of an entry of the wrong shape; a value a codec cannot store; an `expire` that is `NA` or `NaN` |
| `dastash_codec_error` | Encoding or decoding failed; a codec's package is not installed; a record names a codec the handle does not know |
| `dastash_blob_corrupt` | A read finds the file behind a record missing |
| `dastash_busy` | The write lock was not acquired within `timeout` |
| `dastash_store_full` | The database reached its `map_size` |
| `dastash_readonly` | A write on a read-only handle |
| `dastash_config_conflict` | An explicit store-level setting disagrees with the stored one |
| `dastash_version_unsupported` | The store was written by a newer format or key encoding |
| `dastash_forked` | A handle used in a process that did not open it |
| `dastash_closed` | A verb on a closed handle |
| `dastash_unsupported` | The platform or this release cannot do it |
| `dastash_engine_error` | Any other failure of the storage engine, with the original condition as `parent` |

Conditions carry structured fields where they apply, such as `key`,
`dir`, `path` and `codec`, so a handler can act on them without parsing
the message.
