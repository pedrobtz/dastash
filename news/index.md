# Changelog

## dazcache 0.1.0

- Initial CRAN submission.

- A persistent cache shared by every R process on a machine:
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md)
  opens a directory;
  [`cache_get()`](https://pedrobtz.github.io/dazcache/reference/cache_get.md),
  [`cache_set()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md),
  [`cache_has()`](https://pedrobtz.github.io/dazcache/reference/cache_get.md),
  [`cache_delete()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md),
  [`cache_mget()`](https://pedrobtz.github.io/dazcache/reference/cache_get.md)
  and
  [`cache_mset()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md)
  read and write it;
  [`cache_keys()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md),
  [`cache_entries()`](https://pedrobtz.github.io/dazcache/reference/cache_entries.md),
  [`cache_count()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md),
  [`cache_volume()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md)
  and
  [`cache_stats()`](https://pedrobtz.github.io/dazcache/reference/cache_entries.md)
  describe it.

- Keys are text, or any R value the specified key encoding covers
  ([`cache_key()`](https://pedrobtz.github.io/dazcache/reference/cache_key.md)),
  so a cache keyed on function arguments survives R upgrades.

- Small values live in a transactional ‘libmdbx’ database through
  ‘mdbx’; values of `inline_max` bytes or more become read-only,
  content-addressed files, stored once however many keys hold them
  ([`cache_path()`](https://pedrobtz.github.io/dazcache/reference/cache_path.md)).

- Entries expire (`expire =`,
  [`cache_expire()`](https://pedrobtz.github.io/dazcache/reference/cache_expire.md)),
  carry tags (`cache_evict(tag =)`), and are evicted
  least-recently-stored first when the cache holds more than
  `size_limit`
  ([`cache_cull()`](https://pedrobtz.github.io/dazcache/reference/cache_cull.md)).

- Atomic operations across processes:
  [`cache_add()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md),
  [`cache_pop()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md),
  [`cache_touch()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md),
  [`cache_incr()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md),
  [`cache_decr()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md)
  and
  [`cache_transact()`](https://pedrobtz.github.io/dazcache/reference/cache_transact.md).

- [`cache_memoise()`](https://pedrobtz.github.io/dazcache/reference/cache_memoise.md)
  caches a function’s results across sessions and processes;
  [`as_cachem()`](https://pedrobtz.github.io/dazcache/reference/as_cachem.md)
  lets ‘memoise’ and ‘shiny’ use a cache.

- [`cache_check()`](https://pedrobtz.github.io/dazcache/reference/cache_check.md)
  finds and repairs damage, and reclaims what a crash leaves.
