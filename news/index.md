# Changelog

## dastash 0.1.0

- Initial CRAN submission.

- A persistent cache shared by every R process on a machine:
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md)
  opens a directory;
  [`stash_get()`](https://pedrobtz.github.io/dastash/reference/stash_get.md),
  [`stash_set()`](https://pedrobtz.github.io/dastash/reference/stash_set.md),
  [`stash_has()`](https://pedrobtz.github.io/dastash/reference/stash_get.md),
  [`stash_delete()`](https://pedrobtz.github.io/dastash/reference/stash_set.md),
  [`stash_mget()`](https://pedrobtz.github.io/dastash/reference/stash_get.md)
  and
  [`stash_mset()`](https://pedrobtz.github.io/dastash/reference/stash_set.md)
  read and write it;
  [`stash_keys()`](https://pedrobtz.github.io/dastash/reference/stash_keys.md),
  [`stash_entries()`](https://pedrobtz.github.io/dastash/reference/stash_entries.md),
  [`stash_count()`](https://pedrobtz.github.io/dastash/reference/stash_keys.md),
  [`stash_volume()`](https://pedrobtz.github.io/dastash/reference/stash_keys.md)
  and
  [`stash_stats()`](https://pedrobtz.github.io/dastash/reference/stash_entries.md)
  describe it.

- Keys are text, or any R value the specified key encoding covers
  ([`stash_key()`](https://pedrobtz.github.io/dastash/reference/stash_key.md)),
  so a cache keyed on function arguments survives R upgrades.

- Small values live in a transactional ‘libmdbx’ database through
  ‘mdbx’; values of `inline_max` bytes or more become read-only,
  content-addressed files, stored once however many keys hold them
  ([`stash_path()`](https://pedrobtz.github.io/dastash/reference/stash_path.md)).

- Entries expire (`expire =`,
  [`stash_expire()`](https://pedrobtz.github.io/dastash/reference/stash_expire.md)),
  carry tags (`stash_evict(tag =)`), and are evicted
  least-recently-stored first when the cache holds more than
  `size_limit`
  ([`stash_cull()`](https://pedrobtz.github.io/dastash/reference/stash_cull.md)).

- Atomic operations across processes:
  [`stash_add()`](https://pedrobtz.github.io/dastash/reference/stash_add.md),
  [`stash_pop()`](https://pedrobtz.github.io/dastash/reference/stash_add.md),
  [`stash_touch()`](https://pedrobtz.github.io/dastash/reference/stash_add.md),
  [`stash_incr()`](https://pedrobtz.github.io/dastash/reference/stash_add.md),
  [`stash_decr()`](https://pedrobtz.github.io/dastash/reference/stash_add.md)
  and
  [`stash_transact()`](https://pedrobtz.github.io/dastash/reference/stash_transact.md).

- [`stash_memoise()`](https://pedrobtz.github.io/dastash/reference/stash_memoise.md)
  caches a function’s results across sessions and processes;
  [`as_cachem()`](https://pedrobtz.github.io/dastash/reference/as_cachem.md)
  lets ‘memoise’ and ‘shiny’ use a stash.

- [`stash_check()`](https://pedrobtz.github.io/dastash/reference/stash_check.md)
  finds and repairs damage, and reclaims what a crash leaves.
