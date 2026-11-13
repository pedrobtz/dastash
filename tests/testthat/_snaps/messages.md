# a missing key says how to get a default instead

    Code
      cache_get(s, "absent")
    Condition <dazcache_not_found>
      Error in `cache_get()`:
      ! No entry for key "absent".
      i Supply `default` to return a value instead of erroring.

---

    Code
      cache_mget(s, c("a", "b"))
    Condition <dazcache_not_found>
      Error in `cache_mget()`:
      ! No entry for key "a" and 1 more.
      i Supply `default` to return a value for missing keys instead of erroring.

# an unkeyable value says what keys cover

    Code
      cache_key_chr(function() 1)
    Condition <dazcache_key_invalid>
      Error in `cache_key_chr()`:
      ! Cannot use a function in a key.
      i Keys cover strings, numbers, logicals, raw, dates, times, factors, lists and data frames.
      i For a memoised function, leave the argument out with `omit =` or supply `key =`.

# type errors name the argument

    Code
      cache_get(s)
    Condition <dazcache_type_error>
      Error in `cache_get()`:
      ! `key` is required.

---

    Code
      cache_set(s, "k", 1, expire = NA)
    Condition <dazcache_type_error>
      Error in `cache_set()`:
      ! `expire` must be NULL, a number of seconds, a difftime, or a POSIXct; not NA or NaN.

# an unknown codec says how to pass it

    Code
      cache_get(other, "k")
    Condition <dazcache_codec_error>
      Error in `cache_get()`:
      ! This entry was written with the codec "lines", which this handle does not know.
      i Pass the codec to `cache()` in `codecs =`.

# store-level conflicts say to leave the argument out

    Code
      cache(dir, inline_max = 10)
    Condition <dazcache_config_conflict>
      Error in `cache()`:
      ! `inline_max = 10` disagrees with this cache's 1000.
      i Store-level settings are fixed when a cache is created; leave the argument out to use the stored value.

# read-only and closed handles say so

    Code
      cache_set(ro, "k", 1)
    Condition <dazcache_readonly>
      Error in `cache_set()`:
      ! This cache was opened read-only.

---

    Code
      cache_get(s, "k")
    Condition <dazcache_closed>
      Error in `cache_get()`:
      ! This cache has been closed.

# a busy lock says how to wait longer and how a dead writer recovers

    Code
      cache_set(s, "k", 1)
    Condition <dazcache_busy>
      Error in `cache_set()`:
      ! Could not write: another process held the cache's write lock for 0 seconds.
      i Raise `timeout` in `cache()` to wait longer.
      i If a process was killed while writing, this platform never releases its lock: close every handle on this cache, in every process, to recover it.

# a full map says to raise map_size

    Code
      cache_set(s, "k", 1)
    Condition <dazcache_store_full>
      Error in `cache_set()`:
      ! The cache's database is full: it reached its `map_size`.
      i Reopen it with a larger `map_size` in `cache()`.
      Caused by error in `mdbx::mdbx_txn_commit()`:
      ! MDBX_MAP_FULL

