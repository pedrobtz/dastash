# dastash 0.1.0

* Initial CRAN submission.

* A persistent cache shared by every R process on a machine: `stash()` opens
  a directory; `stash_get()`, `stash_set()`, `stash_has()`, `stash_delete()`,
  `stash_mget()` and `stash_mset()` read and write it; `stash_keys()`,
  `stash_entries()`, `stash_count()`, `stash_volume()` and `stash_stats()`
  describe it.

* Keys are text, or any R value the specified key encoding covers
  (`stash_key()`), so a cache keyed on function arguments survives R upgrades.

* Small values live in a transactional 'libmdbx' database through 'mdbx';
  values of `inline_max` bytes or more become read-only, content-addressed
  files, stored once however many keys hold them (`stash_path()`).

* Entries expire (`expire =`, `stash_expire()`), carry tags
  (`stash_evict(tag =)`), and are evicted least-recently-stored first when the
  cache holds more than `size_limit` (`stash_cull()`).

* Atomic operations across processes: `stash_add()`, `stash_pop()`,
  `stash_touch()`, `stash_incr()`, `stash_decr()` and `stash_transact()`.

* `stash_memoise()` caches a function's results across sessions and
  processes; `as_cachem()` lets 'memoise' and 'shiny' use a stash.

* `stash_check()` finds and repairs damage, and reclaims what a crash leaves.
