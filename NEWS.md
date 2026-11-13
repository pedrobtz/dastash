# dazcache 0.1.0

* Initial CRAN submission.

* A persistent cache shared by every R process on a machine: `cache()` opens
  a directory; `cache_get()`, `cache_set()`, `cache_has()`, `cache_delete()`,
  `cache_mget()` and `cache_mset()` read and write it; `cache_keys()`,
  `cache_entries()`, `cache_count()`, `cache_volume()` and `cache_stats()`
  describe it.

* Keys are text, or any R value the specified key encoding covers
  (`cache_key()`), so a cache keyed on function arguments survives R upgrades.

* Small values live in a transactional 'libmdbx' database through 'mdbx';
  values of `inline_max` bytes or more become read-only, content-addressed
  files, stored once however many keys hold them (`cache_path()`).

* Entries expire (`expire =`, `cache_expire()`), carry tags
  (`cache_evict(tag =)`), and are evicted least-recently-stored first when the
  cache holds more than `size_limit` (`cache_cull()`).

* Atomic operations across processes: `cache_add()`, `cache_pop()`,
  `cache_touch()`, `cache_incr()`, `cache_decr()` and `cache_transact()`.

* `cache_memoise()` caches a function's results across sessions and
  processes; `as_cachem()` lets 'memoise' and 'shiny' use a cache.

* `cache_check()` finds and repairs damage, and reclaims what a crash leaves.
