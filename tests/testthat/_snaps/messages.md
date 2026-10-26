# a missing key says how to get a default instead

    Code
      stash_get(s, "absent")
    Condition <dastash_not_found>
      Error in `stash_get()`:
      ! No entry for key "absent".
      i Supply `default` to return a value instead of erroring.

---

    Code
      stash_mget(s, c("a", "b"))
    Condition <dastash_not_found>
      Error in `stash_mget()`:
      ! No entry for key "a" and 1 more.
      i Supply `default` to return a value for missing keys instead of erroring.

# an unkeyable value says what keys cover

    Code
      stash_key_chr(function() 1)
    Condition <dastash_key_invalid>
      Error in `stash_key_chr()`:
      ! Cannot use a function in a key.
      i Keys cover strings, numbers, logicals, raw, dates, times, factors, lists and data frames.
      i For a memoised function, leave the argument out with `omit =` or supply `key =`.

# type errors name the argument

    Code
      stash_get(s)
    Condition <dastash_type_error>
      Error in `stash_get()`:
      ! `key` is required.

---

    Code
      stash_set(s, "k", 1, expire = NA)
    Condition <dastash_type_error>
      Error in `stash_set()`:
      ! `expire` must be NULL, a number of seconds, a difftime, or a POSIXct; not NA or NaN.

# an unknown codec says how to pass it

    Code
      stash_get(other, "k")
    Condition <dastash_codec_error>
      Error in `stash_get()`:
      ! This entry was written with the codec "lines", which this handle does not know.
      i Pass the codec to `stash()` in `codecs =`.

# store-level conflicts say to leave the argument out

    Code
      stash(dir, inline_max = 10)
    Condition <dastash_config_conflict>
      Error in `stash()`:
      ! `inline_max = 10` disagrees with this stash's 1000.
      i Store-level settings are fixed when a stash is created; leave the argument out to use the stored value.

# read-only and closed handles say so

    Code
      stash_set(ro, "k", 1)
    Condition <dastash_readonly>
      Error in `stash_set()`:
      ! This stash was opened read-only.

---

    Code
      stash_get(s, "k")
    Condition <dastash_closed>
      Error in `stash_get()`:
      ! This stash has been closed.

# a busy lock says how to wait longer and how a dead writer recovers

    Code
      stash_set(s, "k", 1)
    Condition <dastash_busy>
      Error in `stash_set()`:
      ! Could not write: another process held the stash's write lock for 0 seconds.
      i Raise `timeout` in `stash()` to wait longer.
      i If a process was killed while writing, this platform never releases its lock: close every handle on this stash, in every process, to recover it.

# a full map says to raise map_size

    Code
      stash_set(s, "k", 1)
    Condition <dastash_store_full>
      Error in `stash_set()`:
      ! The stash's database is full: it reached its `map_size`.
      i Reopen it with a larger `map_size` in `stash()`.
      Caused by error in `mdbx::mdbx_txn_commit()`:
      ! MDBX_MAP_FULL

