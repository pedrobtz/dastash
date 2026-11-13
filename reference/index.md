# Package index

## Open and close

- [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md)
  [`cache_close()`](https://pedrobtz.github.io/dazcache/reference/cache.md)
  [`cache_is_open()`](https://pedrobtz.github.io/dazcache/reference/cache.md)
  [`cache_dir()`](https://pedrobtz.github.io/dazcache/reference/cache.md)
  [`local_cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md)
  [`with_cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md)
  : Open a cache

## Keys and codecs

- [`cache_key()`](https://pedrobtz.github.io/dazcache/reference/cache_key.md)
  [`cache_key_chr()`](https://pedrobtz.github.io/dazcache/reference/cache_key.md)
  [`cache_key_text()`](https://pedrobtz.github.io/dazcache/reference/cache_key.md)
  [`cache_key_hash()`](https://pedrobtz.github.io/dazcache/reference/cache_key.md)
  : Keys
- [`codec()`](https://pedrobtz.github.io/dazcache/reference/codec.md)
  [`codec_auto()`](https://pedrobtz.github.io/dazcache/reference/codec.md)
  [`codec_rds()`](https://pedrobtz.github.io/dazcache/reference/codec.md)
  [`codec_raw()`](https://pedrobtz.github.io/dazcache/reference/codec.md)
  [`codec_file()`](https://pedrobtz.github.io/dazcache/reference/codec.md)
  : Codecs

## Read

- [`cache_get()`](https://pedrobtz.github.io/dazcache/reference/cache_get.md)
  [`cache_mget()`](https://pedrobtz.github.io/dazcache/reference/cache_get.md)
  [`cache_has()`](https://pedrobtz.github.io/dazcache/reference/cache_get.md)
  : Read from a cache
- [`cache_path()`](https://pedrobtz.github.io/dazcache/reference/cache_path.md)
  : The file behind an entry

## Write

- [`cache_set()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md)
  [`cache_mset()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md)
  [`cache_delete()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md)
  : Write to a cache
- [`cache_incr()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md)
  [`cache_decr()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md)
  [`cache_add()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md)
  [`cache_pop()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md)
  [`cache_touch()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md)
  : Atomic writes

## List and describe

- [`cache_keys()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md)
  [`cache_count()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md)
  [`cache_volume()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md)
  : List and count a cache's entries
- [`cache_entries()`](https://pedrobtz.github.io/dazcache/reference/cache_entries.md)
  [`cache_info()`](https://pedrobtz.github.io/dazcache/reference/cache_entries.md)
  [`cache_stats()`](https://pedrobtz.github.io/dazcache/reference/cache_entries.md)
  : The catalogue of a cache

## Maintain

- [`cache_expire()`](https://pedrobtz.github.io/dazcache/reference/cache_expire.md)
  : Reclaim expired entries
- [`cache_cull()`](https://pedrobtz.github.io/dazcache/reference/cache_cull.md)
  [`cache_evict()`](https://pedrobtz.github.io/dazcache/reference/cache_cull.md)
  [`cache_clear()`](https://pedrobtz.github.io/dazcache/reference/cache_cull.md)
  : Keep a cache under its size limit
- [`cache_check()`](https://pedrobtz.github.io/dazcache/reference/cache_check.md)
  : Check a cache, and repair it

## Compose

- [`cache_transact()`](https://pedrobtz.github.io/dazcache/reference/cache_transact.md)
  : Run several writes as one transaction
- [`cache_memoise()`](https://pedrobtz.github.io/dazcache/reference/cache_memoise.md)
  [`cache_memoise_key()`](https://pedrobtz.github.io/dazcache/reference/cache_memoise.md)
  [`cache_forget()`](https://pedrobtz.github.io/dazcache/reference/cache_memoise.md)
  [`cache_forget_all()`](https://pedrobtz.github.io/dazcache/reference/cache_memoise.md)
  [`is_cache_memoised()`](https://pedrobtz.github.io/dazcache/reference/cache_memoise.md)
  : Memoise a function in a cache

## Interoperate

- [`as_cachem()`](https://pedrobtz.github.io/dazcache/reference/as_cachem.md)
  : Use a cache through the cachem interface
- [`length(`*`<dazcache_cache>`*`)`](https://pedrobtz.github.io/dazcache/reference/cache-generics.md)
  [`` `[[`( ``*`<dazcache_cache>`*`)`](https://pedrobtz.github.io/dazcache/reference/cache-generics.md)
  [`` `[[<-`( ``*`<dazcache_cache>`*`)`](https://pedrobtz.github.io/dazcache/reference/cache-generics.md)
  [`as.list(`*`<dazcache_cache>`*`)`](https://pedrobtz.github.io/dazcache/reference/cache-generics.md)
  : Base generics for a cache

## Conditions

- [`dazcache-conditions`](https://pedrobtz.github.io/dazcache/reference/dazcache-conditions.md)
  : Conditions raised by dazcache
